import Foundation
import Combine
import Darwin


private func ticks(forSeconds seconds: Double) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
}

private final class SenderSession {
    private let capture = AudioCapture()
    private let playback = AudioPlayback()
    private let transport: RelaySender
    private let onError: (Error) -> Void
    private var clock = AudioTimeline()

    init(onState: @escaping (RelayTransportState) -> Void, onError: @escaping (Error) -> Void) throws {
        transport = try RelaySender(onState: onState)
        self.onError = onError
        capture.onError = onError
        playback.onError = onError
    }

    func start() throws {
        try playback.start()
        transport.start()
        try capture.start { [weak self] input, capturedAt in
            guard let self = self, !input.isEmpty else { return }
            let (data, time) = self.clock.schedule(input, targetTime: capturedAt + ticks(forSeconds: 0.6))
            self.playback.enqueue(data, atHostTime: time)
            if case .overloaded = self.transport.sendPCM(data, playbackTime: time) {
                self.onError(NSError(domain: "SoundMashRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Сеть не успевает передавать звук. Сеанс остановлен."]))
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        capture.stop()
        playback.stop()
        transport.stop(completion: completion)
    }
}

private final class ReceiverSession {
    private let playback = AudioPlayback()
    private var transport: RelayReceiver?
    private let lock = NSLock()
    private var adjustment: Double = 0
    private var clock = AudioTimeline()

    init(host: String, onState: @escaping (RelayTransportState) -> Void, onError: @escaping (Error) -> Void) throws {
        playback.onError = onError
        transport = try RelayReceiver(host: host, onPCM: { [weak self] data, time in
            guard let self = self else { return }
            self.lock.lock()
            let adjustment = self.adjustment
            self.lock.unlock()
            let shift = ticks(forSeconds: abs(adjustment) / 1000)
            let adjusted = adjustment < 0 ? (time > shift ? time - shift : 0) : time &+ shift
            let (corrected, scheduled) = self.clock.schedule(data, targetTime: adjusted)
            guard scheduled > mach_absolute_time() + ticks(forSeconds: 0.01) else {
                onError(NSError(domain: "SoundMashRelay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Аудиопакет пришёл слишком поздно. Сеанс остановлен."]))
                return
            }
            self.playback.enqueue(corrected, atHostTime: scheduled)
        }, onState: onState)
    }

    func setAdjustment(_ ms: Double) {
        lock.lock()
        adjustment = ms
        lock.unlock()
    }

    func start() throws {
        try playback.start()
        transport?.start()
    }

    func stop() {
        transport?.stop()
        playback.stop()
    }
}

final class RelayModel: ObservableObject {
    @Published var host = ""
    @Published var adjustmentMs: Double = 0 {
        didSet { receiver?.setAdjustment(adjustmentMs) }
    }
    @Published private(set) var running = false
    @Published private(set) var status = "Готово. Поток не шифруется: используйте только доверенную сеть."
    @Published private(set) var hasError = false
    @Published private(set) var localAddresses = RelayModel.addresses()
    private var sender: SenderSession?
    private var receiver: ReceiverSession?
    private var generation = UUID()

    func startSender() {
        guard !running else { return }
        localAddresses = Self.addresses()
        generation = UUID()
        let current = generation
        do {
            let session = try SenderSession(onState: stateHandler(generation: current), onError: audioErrorHandler(generation: current))
            sender = session
            running = true
            hasError = false
            status = "Запуск отправителя…"
            try session.start()
        } catch {
            stop()
            hasError = true
            status = "Не удалось запустить отправитель: \(error.localizedDescription)"
        }
    }

    func startReceiver() {
        guard !running else { return }
        generation = UUID()
        let current = generation
        do {
            let session = try ReceiverSession(host: host.trimmingCharacters(in: .whitespacesAndNewlines), onState: stateHandler(generation: current), onError: audioErrorHandler(generation: current))
            receiver = session
            session.setAdjustment(adjustmentMs)
            running = true
            hasError = false
            status = "Подключение…"
            try session.start()
        } catch {
            generation = UUID()
            receiver?.stop()
            receiver = nil
            running = false
            hasError = true
            status = "Не удалось запустить приёмник: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard sender != nil || receiver != nil else { return }
        generation = UUID()
        let current = generation
        let oldSender = sender
        sender = nil
        receiver?.stop()
        receiver = nil
        hasError = false
        status = "Остановка…"
        if let oldSender = oldSender {
            oldSender.stop { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == current else { return }
                    self.running = false
                    if self.status == "Остановка…" {
                        self.status = "Остановлено. Поток не шифруется: используйте только доверенную сеть."
                    }
                }
            }
        } else {
            running = false
            status = "Остановлено. Поток не шифруется: используйте только доверенную сеть."
        }
    }

    private func audioErrorHandler(generation: UUID) -> (Error) -> Void {
        { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                self.stop()
                self.hasError = true
                self.status = "Ошибка аудио: \(error.localizedDescription)"
            }
        }
    }

    private func stateHandler(generation: UUID) -> (RelayTransportState) -> Void {
        { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                switch state {
                case .waiting: self.status = "Ожидание подключения второго Mac…"; self.hasError = false
                case .connecting: self.status = "Подключение…"; self.hasError = false
                case .connected: self.status = "Соединение установлено."; self.hasError = false
                case .disconnected(let reason):
                    self.stop()
                    self.status = "Соединение закрыто\(reason.map { ": \($0)" } ?? ".")"
                    self.hasError = true
                case .failed(let reason):
                    self.stop()
                    self.status = "Ошибка сети: \(reason)"
                    self.hasError = true
                case .stopped: self.status = "Остановлено."
                }
            }
        }
    }

    private static func addresses() -> String {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return "не найден" }
        defer { freeifaddrs(first) }
        var values: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = start
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            values.append("\(String(cString: entry.pointee.ifa_name)): \(String(cString: buffer))")
        }
        return values.isEmpty ? "не найден" : values.joined(separator: ", ")
    }
}
