import Foundation
import AVFoundation
import CoreAudio
import Darwin

// Wire format: 48 kHz, two channels, interleaved native-endian IEEE Float32
// (little-endian on supported Macs), left sample first; eight bytes per frame.
private let relaySampleRate: Double = 48_000
private let relayFrameBytes = 8

private enum AudioCoreError: LocalizedError {
    case status(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .status(operation, status): return "\(operation) failed (OSStatus \(status))"
        case let .message(message): return message
        }
    }
}

private func checkAudioStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioCoreError.status(operation, status) }
}

private func reportAudioError(_ error: Error, handler: ((Error) -> Void)?) {
    if let handler = handler {
        handler(error)
    } else {
        NSLog("AudioCore: %@", error.localizedDescription)
    }
}

// The IOProc copies each borrowed Core Audio input buffer before returning. Conversion
// and the client's callback happen on a separate serial queue, never on the IO thread.
private final class CaptureWorker {
    private let queue = DispatchQueue(label: "AudioCore.capture.conversion", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var pending = 0
    private let maxPending = 32
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let onAudio: (Data, UInt64) -> Void
    private var packetizer = AudioPacketizer()
    private var flushScheduled = false
    private var lastAudioUptime: UInt64 = 0
    private var captureTimestamp: CaptureTimestamp
    private let onError: ((Error) -> Void)?

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat,
         converter: AVAudioConverter, onAudio: @escaping (Data, UInt64) -> Void,
         onError: ((Error) -> Void)?) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.captureTimestamp = CaptureTimestamp(inputRate: inputFormat.sampleRate, outputRate: outputFormat.sampleRate)
        self.onAudio = onAudio
        self.onError = onError
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    private func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func receive(_ input: UnsafePointer<AudioBufferList>, capturedAt: UInt64) {
        lock.lock()
        guard active, pending < maxPending else {
            let overflow = active && pending == maxPending
            if overflow { pending += 1 }
            lock.unlock()
            if overflow {
                queue.async { [self] in
                    if isActive() {
                        reportAudioError(AudioCoreError.message("Capture conversion queue overflow; audio was dropped"), handler: onError)
                    }
                    lock.lock()
                    pending -= 1
                    lock.unlock()
                }
            }
            return
        }
        pending += 1
        lock.unlock()

        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, !source.isEmpty,
              source.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= bytesPerFrame }) else {
            finishPending()
            return
        }
        let frames = source.reduce(Int.max) { min($0, Int($1.mDataByteSize) / bytesPerFrame) }
        guard frames > 0, frames <= Int(UInt32.max),
              let copy = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            finishPending()
            return
        }
        copy.frameLength = AVAudioFrameCount(frames)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else {
            finishPending()
            queue.async { [self] in
                if isActive() { reportAudioError(AudioCoreError.message("Unexpected tap buffer layout"), handler: onError) }
            }
            return
        }
        let byteCount = frames * bytesPerFrame
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData,
                  Int(destination[index].mDataByteSize) >= byteCount else {
                finishPending()
                return
            }
            memcpy(dst, src, byteCount)
        }
        queue.async { [self] in
            defer { finishPending() }
            guard isActive() else { return }
            let estimated = ceil(Double(frames) * outputFormat.sampleRate / inputFormat.sampleRate) + 512
            guard estimated > 0, estimated <= Double(UInt32.max),
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(estimated)) else {
                reportAudioError(AudioCoreError.message("Cannot allocate converted capture buffer"), handler: onError)
                return
            }
            var supplied = false
            var conversionError: NSError?
            let result = converter.convert(to: output, error: &conversionError) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return copy
            }
            if result == .error {
                if let conversionError = conversionError {
                    reportAudioError(conversionError, handler: onError)
                } else {
                    reportAudioError(AudioCoreError.message("Audio conversion failed"), handler: onError)
                }
                return
            }
            guard supplied else {
                reportAudioError(AudioCoreError.message("Audio converter did not consume the capture buffer"), handler: onError)
                return
            }
            guard isActive() else { return }
            let outputFrames = Int(output.frameLength)
            let converted: Data
            if outputFrames > 0 {
                let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                guard buffers.count == 1, let data = buffers[0].mData else {
                    reportAudioError(AudioCoreError.message("Unexpected converted audio buffer layout"), handler: onError)
                    return
                }
                converted = Data(bytes: data, count: outputFrames * relayFrameBytes)
            } else {
                converted = Data()
            }
            do {
                try captureTimestamp.map(capturedAt: capturedAt, inputFrames: frames, outputFrames: outputFrames) { offset, count, time in
                    let range = (offset * relayFrameBytes)..<((offset + count) * relayFrameBytes)
                    let chunk = offset == 0 && count == outputFrames ? converted : converted.subdata(in: range)
                    try packetizer.append(chunk, capturedAt: time, emit: onAudio)
                }
            } catch {
                reportAudioError(error, handler: onError)
                return
            }
            if outputFrames > 0 {
                lastAudioUptime = DispatchTime.now().uptimeNanoseconds
                if packetizer.hasPending && !flushScheduled { schedulePendingFlush() }
            }
        }
    }

    private func schedulePendingFlush() {
        flushScheduled = true
        let deadline = lastAudioUptime + 30_000_000
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
            guard let self = self, self.isActive() else { return }
            if DispatchTime.now().uptimeNanoseconds < self.lastAudioUptime + 30_000_000 {
                self.schedulePendingFlush()
                return
            }
            self.flushScheduled = false
            do {
                try self.packetizer.flush(emit: self.onAudio)
            } catch {
                reportAudioError(error, handler: self.onError)
            }
        }
    }

    private func finishPending() {
        lock.lock()
        pending -= 1
        lock.unlock()
    }
}

/// Captures other processes' output and mutes their direct output while the tap is read.
/// Set onError before start to receive asynchronous errors; otherwise they are logged.
/// start/stop are serialized internally. A callback already executing may finish after stop.
final class AudioCapture {
    var onError: ((Error) -> Void)?
    private let lock = NSLock()
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var worker: CaptureWorker?

    func start(onAudio: @escaping (Data, UInt64) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tapID == kAudioObjectUnknown else {
            throw AudioCoreError.message("Audio capture is already started")
        }
        do {
            var pid = getpid()
            var processID = AudioObjectID(kAudioObjectUnknown)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try checkAudioStatus(AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processID), "Find own audio process")
            guard processID != kAudioObjectUnknown else {
                throw AudioCoreError.message("Own Core Audio process object is unavailable; start playback first")
            }

            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [processID])
            description.name = "Sound Mash Relay Tap"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try checkAudioStatus(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")

            var asbd = AudioStreamBasicDescription()
            address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checkAudioStatus(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "Read tap format")
            guard asbd.mSampleRate > 0, asbd.mBytesPerFrame > 0,
                  let inputFormat = AVAudioFormat(streamDescription: &asbd),
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: relaySampleRate, channels: 2, interleaved: true),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioCoreError.message("Unsupported tap audio format")
            }

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Sound Mash Relay Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]]
            ]
            try checkAudioStatus(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Create tap aggregate device")
            let captureWorker = CaptureWorker(inputFormat: inputFormat, outputFormat: outputFormat,
                                              converter: converter, onAudio: onAudio, onError: onError)
            worker = captureWorker
            try checkAudioStatus(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, input, inputTime, _, _ in
                let time = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : mach_absolute_time()
                captureWorker.receive(input, capturedAt: time)
            }, "Create capture IO procedure")
            guard let ioProc = ioProc else { throw AudioCoreError.message("Capture IO procedure was not created") }
            try checkAudioStatus(AudioDeviceStart(aggregateID, ioProc), "Start capture device")
            started = true
        } catch {
            cleanup()
            throw error
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanup()
    }

    private func cleanup() {
        worker?.invalidate()
        if started, let ioProc = ioProc {
            let status = AudioDeviceStop(aggregateID, ioProc)
            if status != noErr { reportAudioError(AudioCoreError.status("Stop capture device", status), handler: nil) }
        }
        started = false
        if let ioProc = ioProc, aggregateID != kAudioObjectUnknown {
            let status = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            if status != noErr { reportAudioError(AudioCoreError.status("Destroy capture IO procedure", status), handler: nil) }
        }
        ioProc = nil
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { reportAudioError(AudioCoreError.status("Destroy tap aggregate device", status), handler: nil) }
        }
        aggregateID = kAudioObjectUnknown
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr { reportAudioError(AudioCoreError.status("Destroy process tap", status), handler: nil) }
        }
        tapID = kAudioObjectUnknown
        worker = nil
    }

    deinit { stop() }
}

/// Schedules PCM on the local mach_absolute_time clock. Supply timestamps far enough
/// in the future for transport, engine and device buffering; playback is not a clock sync.
final class AudioPlayback {
    var onError: ((Error) -> Void)?
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    private var pendingFrames = 0
    private var pendingBuffers = 0

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { throw AudioCoreError.message("Audio playback is already started") }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: relaySampleRate, channels: 2) else {
            throw AudioCoreError.message("Cannot create playback format")
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.stop()
            engine.detach(player)
            throw error
        }
        player.play()
        self.format = format
        self.player = player
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let self = self, let engine = engine else { return }
                self.lock.lock()
                let stillActive = self.engine === engine
                let handler = self.onError
                self.lock.unlock()
                if stillActive {
                    reportAudioError(AudioCoreError.message("Audio output configuration changed; session stopped"), handler: handler)
                }
            }
        }
    }

    func enqueue(_ pcm: Data, atHostTime: UInt64) {
        lock.lock()
        guard let player = player, let format = format, let engine = engine, engine.isRunning else {
            lock.unlock()
            reportAudioError(AudioCoreError.message("Cannot enqueue audio before playback starts"), handler: onError)
            return
        }
        guard pcm.count >= 32 * relayFrameBytes, pcm.count % relayFrameBytes == 0,
              pcm.count / relayFrameBytes <= Int(UInt32.max), atHostTime != 0 else {
            lock.unlock()
            reportAudioError(AudioCoreError.message("Invalid PCM buffer or host timestamp"), handler: onError)
            return
        }
        let frames = pcm.count / relayFrameBytes
        let now = mach_absolute_time()
        guard atHostTime > now, AVAudioTime.seconds(forHostTime: atHostTime - now) <= 2,
              frames <= 96_000 - pendingFrames, pendingBuffers < 4096 else {
            lock.unlock()
            reportAudioError(AudioCoreError.message("Playback queue exceeded its timing or size limit"), handler: onError)
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            lock.unlock()
            reportAudioError(AudioCoreError.message("Cannot allocate playback buffer"), handler: onError)
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { bytes in
            for frame in 0..<frames {
                channels[0][frame] = bytes.loadUnaligned(fromByteOffset: frame * relayFrameBytes, as: Float.self)
                channels[1][frame] = bytes.loadUnaligned(fromByteOffset: frame * relayFrameBytes + 4, as: Float.self)
            }
        }
        pendingFrames += frames
        pendingBuffers += 1
        player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: atHostTime), options: [], completionCallbackType: .dataPlayedBack) { [weak self, weak engine] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let self = self, let engine = engine else { return }
                self.lock.lock()
                if self.engine === engine {
                    self.pendingFrames = max(0, self.pendingFrames - frames)
                    self.pendingBuffers = max(0, self.pendingBuffers - 1)
                }
                self.lock.unlock()
            }
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        player?.stop()
        engine?.stop()
        if let engine = engine, let player = player { engine.detach(player) }
        player = nil
        engine = nil
        format = nil
        pendingFrames = 0
        pendingBuffers = 0
    }

    deinit { stop() }
}
