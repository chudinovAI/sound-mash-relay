import Foundation
import Network
import Darwin

/// Connection status callbacks run on the transport's private serial queue.
public enum RelayTransportState {
    case waiting
    case connecting
    case connected
    case disconnected(String?)
    case failed(String)
    case stopped
}

public enum RelayTransportError: Error {
    case invalidPort
    case invalidAddress
}

// Wire format: one-byte type, four-byte unsigned big-endian payload length,
// then payload. Integers in payloads are unsigned big-endian. Type 1 is an
// eight-byte sender-clock nanosecond playback time followed by PCM. Type 2
// is a receiver-clock nanosecond timestamp. Type 3 echoes that timestamp and
// adds the sender's receive and transmit timestamps (eight bytes each).
// This is a private, unversioned protocol, not a general-purpose audio codec.
private enum RelayWire {
    static let audio: UInt8 = 1
    static let ping: UInt8 = 2
    static let pong: UInt8 = 3
    static let maxPCMBytes = 256 * 1024
    static let maxPayloadBytes = maxPCMBytes + 8
    static let maxQueuedAudioBytes = 256 * 1024
    static let maxQueuedAudioBlocks = 128
    static let maxControlReplies = 16

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        let start = data.index(data.startIndex, offsetBy: offset)
        for byte in data[start..<data.index(start, offsetBy: 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    static func frame(type: UInt8, payload: Data) -> Data {
        var result = Data(capacity: 5 + payload.count)
        result.append(type)
        appendUInt32(UInt32(payload.count), to: &result)
        result.append(payload)
        return result
    }
}

private enum RelayProtocolError: Error {
    case invalidFrame
}

/// Receives at most one maximum-sized frame plus one 64 KiB network chunk.
private final class RelayFramer {
    private var bytes = Data()

    func consume(_ chunk: Data, handle: (UInt8, Data) throws -> Void) throws {
        bytes.append(chunk)
        while bytes.count >= 5 {
            let start = bytes.startIndex
            let type = bytes[start]
            var length: UInt32 = 0
            for offset in 1...4 {
                length = (length << 8) | UInt32(bytes[bytes.index(start, offsetBy: offset)])
            }
            guard Int(length) <= RelayWire.maxPayloadBytes else {
                throw RelayProtocolError.invalidFrame
            }
            let frameSize = 5 + Int(length)
            guard bytes.count >= frameSize else { return }
            let payloadStart = bytes.index(start, offsetBy: 5)
            let end = bytes.index(start, offsetBy: frameSize)
            let payload = bytes.subdata(in: payloadStart..<end)
            bytes.removeSubrange(start..<end)
            try handle(type, payload)
        }
    }
}

/// The wire clock is in nanoseconds, not mach ticks, because each machine's
/// mach timebase can differ. Double arithmetic avoids integer multiplication
/// overflow; at typical uptimes its rounding error is much smaller than a
/// network scheduling interval.
private enum RelayClock {
    static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64? {
        let value = Double(ticks) * nanosecondsPerTick
        guard value.isFinite, value >= 0, value < 18_446_744_073_709_551_616.0 else { return nil }
        return UInt64(value)
    }

    static func ticks(_ nanoseconds: Double) -> UInt64? {
        let value = nanoseconds / nanosecondsPerTick
        guard value.isFinite, value >= 0, value < 18_446_744_073_709_551_616.0 else { return nil }
        return UInt64(value)
    }

    static func now() -> UInt64 {
        // macOS mach timebase and uptime fit in UInt64 nanoseconds in practice.
        nanoseconds(mach_absolute_time()) ?? UInt64.max
    }
}

/// Listens on all interfaces on `port` and serves at most one receiver.
/// No encryption or authentication is provided; firewall/routing determine
/// reachability, including from outside the LAN. VPN settings are untouched.
///
/// `sendPCM` runs on the capture conversion queue, not the Core Audio IO thread.
/// It distinguishes an absent receiver from a full queue, so a lost block during
/// an active session can be reported instead of silently desynchronizing.
/// Pending audio is discarded on disconnect. `playbackTime` is in local mach ticks.
/// PCM format is agreed by the application: 48 kHz stereo interleaved Float32.
/// `onState` must return promptly and must not synchronously wait for transport.
public enum RelaySendResult {
    case queued, noReceiver, overloaded
}

public final class RelaySender {
    private final class AudioItem {
        let data: Data
        let playbackTime: UInt64
        var reserved = true
        init(data: Data, playbackTime: UInt64) {
            self.data = data
            self.playbackTime = playbackTime
        }
    }

    private let port: NWEndpoint.Port
    private let onState: (RelayTransportState) -> Void
    private let queue = DispatchQueue(label: "sound-mash-relay.sender")
    private let reservationLock = NSLock()
    // These fields alone are accessed from the audio thread.
    private var acceptingAudio = false
    private var generation: UInt64 = 0
    private var reservedBytes = 0
    private var reservedBlocks = 0

    // All other state is confined to queue.
    private var listener: NWListener?
    private var connection: NWConnection?
    private var framer = RelayFramer()
    private var audioQueue: [AudioItem] = []
    private var replies: [(UInt64, UInt64)] = []
    private var inFlightAudio: AudioItem?
    private var sending = false
    private var connectionReady = false

    public init(port: UInt16 = 45987, onState: @escaping (RelayTransportState) -> Void = { _ in }) throws {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw RelayTransportError.invalidPort
        }
        self.port = endpointPort
        self.onState = onState
    }

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    public func stop(completion: @escaping () -> Void = {}) {
        queue.async {
            self.closeConnection(reason: nil, notify: false)
            guard let listener = self.listener else {
                self.onState(.stopped)
                completion()
                return
            }
            listener.stateUpdateHandler = { [self] state in
                if case .cancelled = state {
                    self.listener = nil
                    self.onState(.stopped)
                    completion()
                }
            }
            listener.cancel()
        }
    }

    @discardableResult
    public func sendPCM(_ data: Data, playbackTime: UInt64) -> RelaySendResult {
        guard !data.isEmpty, data.count <= RelayWire.maxPCMBytes,
              RelayClock.nanoseconds(playbackTime) != nil else { return .overloaded }
        reservationLock.lock()
        guard acceptingAudio else {
            reservationLock.unlock()
            return .noReceiver
        }
        guard reservedBlocks < RelayWire.maxQueuedAudioBlocks,
              reservedBytes <= RelayWire.maxQueuedAudioBytes - data.count else {
            reservationLock.unlock()
            return .overloaded
        }
        reservedBytes += data.count
        reservedBlocks += 1
        let acceptedGeneration = generation
        reservationLock.unlock()
        let item = AudioItem(data: data, playbackTime: playbackTime)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.reservationLock.lock()
            let valid = self.acceptingAudio && self.generation == acceptedGeneration
            self.reservationLock.unlock()
            guard valid, self.connectionReady else {
                self.release(item)
                return
            }
            self.audioQueue.append(item)
            self.sendNext()
        }
        return .queued
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        do {
            let newListener = try NWListener(using: .tcp, on: port)
            listener = newListener
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self = self, let newListener = newListener,
                      self.listener === newListener else { return }
                switch state {
                case .ready: self.onState(.waiting)
                case .failed(let error):
                    self.closeConnection(reason: nil, notify: false)
                    self.onState(.failed(error.localizedDescription))
                default: break
                }
            }
            newListener.newConnectionHandler = { [weak self] incoming in
                guard let self = self, self.listener != nil else {
                    incoming.cancel()
                    return
                }
                guard self.connection == nil else {
                    incoming.cancel()
                    return
                }
                self.accept(incoming)
            }
            newListener.start(queue: queue)
        } catch {
            onState(.failed(error.localizedDescription))
        }
    }

    private func accept(_ incoming: NWConnection) {
        connection = incoming
        framer = RelayFramer()
        onState(.connecting)
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            guard let self = self, let incoming = incoming,
                  self.connection === incoming else { return }
            switch state {
            case .ready:
                self.connectionReady = true
                self.reservationLock.lock()
                self.generation &+= 1
                self.acceptingAudio = true
                self.reservationLock.unlock()
                self.onState(.connected)
                self.receive(on: incoming)
                self.sendNext()
            case .failed(let error): self.closeConnection(reason: error.localizedDescription, notify: true)
            case .cancelled: self.closeConnection(reason: nil, notify: true)
            default: break
            }
        }
        incoming.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self = self, let connection = connection,
                  self.connection === connection else { return }
            do {
                if let data = data, !data.isEmpty {
                    try self.framer.consume(data) { type, payload in
                        guard type == RelayWire.ping, payload.count == 8,
                              self.replies.count < RelayWire.maxControlReplies else {
                            throw RelayProtocolError.invalidFrame
                        }
                        self.replies.append((RelayWire.uint64(payload, at: 0), RelayClock.now()))
                    }
                    self.sendNext()
                }
            } catch {
                self.closeConnection(reason: "Invalid or excessive protocol data", notify: true)
                return
            }
            if let error = error {
                self.closeConnection(reason: error.localizedDescription, notify: true)
            } else if complete {
                self.closeConnection(reason: nil, notify: true)
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func sendNext() {
        guard !sending, connectionReady, let connection = connection else { return }
        let frame: Data
        if !replies.isEmpty {
            let (receiverTime, receivedTime) = replies.removeFirst()
            var payload = Data(capacity: 24)
            RelayWire.appendUInt64(receiverTime, to: &payload)
            RelayWire.appendUInt64(receivedTime, to: &payload)
            RelayWire.appendUInt64(RelayClock.now(), to: &payload)
            frame = RelayWire.frame(type: RelayWire.pong, payload: payload)
        } else if !audioQueue.isEmpty {
            let item = audioQueue.removeFirst()
            guard let time = RelayClock.nanoseconds(item.playbackTime) else {
                release(item)
                sendNext()
                return
            }
            guard time > RelayClock.now() + 50_000_000 else {
                release(item)
                closeConnection(reason: "Audio network deadline missed", notify: true)
                return
            }
            inFlightAudio = item
            var audioFrame = Data(capacity: 13 + item.data.count)
            audioFrame.append(RelayWire.audio)
            RelayWire.appendUInt32(UInt32(8 + item.data.count), to: &audioFrame)
            RelayWire.appendUInt64(time, to: &audioFrame)
            audioFrame.append(item.data)
            frame = audioFrame
        } else {
            return
        }
        sending = true
        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self = self, let connection = connection,
                  self.connection === connection else { return }
            if let item = self.inFlightAudio {
                self.inFlightAudio = nil
                self.release(item)
            }
            self.sending = false
            if let error = error {
                self.closeConnection(reason: error.localizedDescription, notify: true)
            } else {
                self.sendNext()
            }
        })
    }

    private func release(_ item: AudioItem) {
        guard item.reserved else { return }
        item.reserved = false
        reservationLock.lock()
        reservedBytes -= item.data.count
        reservedBlocks -= 1
        reservationLock.unlock()
    }

    private func closeConnection(reason: String?, notify: Bool) {
        let old = connection
        connection = nil
        connectionReady = false
        reservationLock.lock()
        acceptingAudio = false
        generation &+= 1
        reservationLock.unlock()
        for item in audioQueue { release(item) }
        audioQueue.removeAll()
        if let item = inFlightAudio { release(item) }
        inFlightAudio = nil
        replies.removeAll()
        sending = false
        framer = RelayFramer()
        old?.cancel()
        if notify && old != nil { onState(.disconnected(reason)) }
    }
}

/// Connects to a numeric IPv4 or IPv6 address. `onPCM` receives the raw PCM and
/// its playback time converted to this Mac's mach_absolute_time ticks. It runs
/// on the internal serial queue and must return promptly. Audio is dropped until
/// at least three valid clock exchanges have completed. Clock offset is updated
/// from the lowest-RTT sample among the latest eight valid exchanges. Probes run
/// every 250 ms and a watchdog closes a stalled connection.
/// Timing is an estimate, not sample-accurate synchronization; it depends on
/// network asymmetry and scheduler jitter. No resampling, clock-drift correction,
/// authentication, encryption, discovery, or VPN manipulation is provided.
public final class RelayReceiver {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let onPCM: (Data, UInt64) -> Void
    private let onState: (RelayTransportState) -> Void
    private let queue = DispatchQueue(label: "sound-mash-relay.receiver")
    private var connection: NWConnection?
    private var framer = RelayFramer()
    private var timer: DispatchSourceTimer?
    private var lastPong: UInt64 = 0
    private var lastAudio: UInt64 = 0
    private var connectedAt: UInt64 = 0
    private var pingSending = false
    private var outstanding: [UInt64] = []
    private var samples: [(rtt: Double, offset: Double)] = []

    public init(host: String, port: UInt16 = 45987,
                onPCM: @escaping (Data, UInt64) -> Void,
                onState: @escaping (RelayTransportState) -> Void = { _ in }) throws {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw RelayTransportError.invalidPort
        }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let valid = host.withCString { address in
            inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1
        }
        guard valid else { throw RelayTransportError.invalidAddress }
        self.host = NWEndpoint.Host(host)
        self.port = endpointPort
        self.onPCM = onPCM
        self.onState = onState
    }

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    public func stop() {
        queue.async {
            self.close(reason: nil, notify: false)
            self.onState(.stopped)
        }
    }

    private func startOnQueue() {
        guard connection == nil else { return }
        let newConnection = NWConnection(host: host, port: port, using: .tcp)
        connection = newConnection
        framer = RelayFramer()
        samples.removeAll()
        outstanding.removeAll()
        lastPong = RelayClock.now()
        lastAudio = 0
        pingSending = false
        onState(.connecting)
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self = self, let newConnection = newConnection,
                  self.connection === newConnection else { return }
            switch state {
            case .ready:
                self.lastPong = RelayClock.now()
                self.connectedAt = self.lastPong
                self.onState(.connected)
                self.receive(on: newConnection)
                self.startProbes()
            case .waiting(let error): self.close(reason: error.localizedDescription, notify: true)
            case .failed(let error): self.close(reason: error.localizedDescription, notify: true)
            case .cancelled: self.close(reason: nil, notify: true)
            default: break
            }
        }
        newConnection.start(queue: queue)
    }

    private func startProbes() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = RelayClock.now()
            if now - self.lastPong > 3_000_000_000 {
                self.close(reason: "No clock responses from sender", notify: true)
                return
            }
            if self.lastAudio == 0 && now - self.connectedAt > 3_000_000_000 {
                self.close(reason: "No audio received from sender", notify: true)
                return
            }
            if self.lastAudio != 0 && now - self.lastAudio > 1_000_000_000 {
                self.close(reason: "Audio stream stalled", notify: true)
                return
            }
            _ = self.sendProbe()
        }
        timer.resume()
    }

    private func sendProbe() -> Bool {
        guard !pingSending, let connection = connection else { return false }
        let now = RelayClock.now()
        if outstanding.count == 16 { outstanding.removeFirst() }
        outstanding.append(now)
        var payload = Data(capacity: 8)
        RelayWire.appendUInt64(now, to: &payload)
        pingSending = true
        connection.send(content: RelayWire.frame(type: RelayWire.ping, payload: payload),
                        completion: .contentProcessed { [weak self, weak connection] error in
            guard let self = self, let connection = connection,
                  self.connection === connection else { return }
            self.pingSending = false
            if let error = error { self.close(reason: error.localizedDescription, notify: true) }
        })
        return true
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self = self, let connection = connection,
                  self.connection === connection else { return }
            do {
                if let data = data, !data.isEmpty {
                    try self.framer.consume(data) { type, payload in
                        try self.handle(type: type, payload: payload)
                    }
                }
            } catch {
                self.close(reason: "Invalid protocol data", notify: true)
                return
            }
            if let error = error {
                self.close(reason: error.localizedDescription, notify: true)
            } else if complete {
                self.close(reason: nil, notify: true)
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func handle(type: UInt8, payload: Data) throws {
        switch type {
        case RelayWire.pong:
            guard payload.count == 24 else { throw RelayProtocolError.invalidFrame }
            let t1 = RelayWire.uint64(payload, at: 0)
            let t2 = RelayWire.uint64(payload, at: 8)
            let t3 = RelayWire.uint64(payload, at: 16)
            let t4 = RelayClock.now()
            guard let index = outstanding.firstIndex(of: t1) else { return }
            outstanding.remove(at: index)
            guard t4 >= t1, t3 >= t2 else { return }
            let roundTrip = Double(t4 - t1) - Double(t3 - t2)
            guard roundTrip >= 0, roundTrip <= 5_000_000_000 else { return }
            lastPong = t4
            let offset = ((Double(t2) - Double(t1)) + (Double(t3) - Double(t4))) / 2
            samples.append((roundTrip, offset))
            if samples.count > 8 { samples.removeFirst() }
        case RelayWire.audio:
            guard payload.count >= 8 + 64 * 8, (payload.count - 8) % 8 == 0,
                  payload.count <= RelayWire.maxPayloadBytes else {
                throw RelayProtocolError.invalidFrame
            }
            guard samples.count >= 3, let best = samples.min(by: { $0.rtt < $1.rtt }) else { return }
            let senderTime = RelayWire.uint64(payload, at: 0)
            guard let localTime = RelayClock.ticks(Double(senderTime) - best.offset) else { return }
            lastAudio = RelayClock.now()
            let start = payload.index(payload.startIndex, offsetBy: 8)
            onPCM(payload.subdata(in: start..<payload.endIndex), localTime)
        default:
            throw RelayProtocolError.invalidFrame
        }
    }

    private func close(reason: String?, notify: Bool) {
        let old = connection
        connection = nil
        timer?.cancel()
        timer = nil
        outstanding.removeAll()
        samples.removeAll()
        pingSending = false
        framer = RelayFramer()
        old?.cancel()
        if notify && old != nil { onState(.disconnected(reason)) }
    }
}
