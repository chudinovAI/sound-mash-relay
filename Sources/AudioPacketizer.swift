import Foundation
import AVFoundation

private enum AudioPacketizerError: LocalizedError {
    case captureGapTooLong
    case captureTimeWentBackwards

    var errorDescription: String? {
        switch self {
        case .captureGapTooLong: return "Захват звука прервался более чем на 100 мс."
        case .captureTimeWentBackwards: return "Временные метки захвата звука пошли назад."
        }
    }
}

/// Batches 48 kHz stereo Float32 audio while preserving its sample timeline.
/// Brief capture gaps are filled with silence; longer gaps are reported as errors.
struct AudioPacketizer {
    private let bytesPerFrame = 8
    private let minimumFrames = 1024
    private let maximumFrames = 4096
    private var pending = Data()
    private var pendingTime: UInt64 = 0
    private var lastEmittedEnd: UInt64?
    private var lastCapturedStart: UInt64?
    private var lastCapturedEnd: UInt64?

    var hasPending: Bool { !pending.isEmpty }

    mutating func append(_ pcm: Data, capturedAt: UInt64, emit: (Data, UInt64) -> Void) throws {
        precondition(pcm.count % bytesPerFrame == 0)
        guard !pcm.isEmpty else { return }
        if let previous = lastCapturedStart, capturedAt < previous {
            throw AudioPacketizerError.captureTimeWentBackwards
        }
        if let previousEnd = lastCapturedEnd, capturedAt > previousEnd,
           AVAudioTime.seconds(forHostTime: capturedAt - previousEnd) > 0.1 {
            throw AudioPacketizerError.captureGapTooLong
        }
        if pending.isEmpty, let previousEnd = lastCapturedEnd, let emittedEnd = lastEmittedEnd {
            let silenceStart = max(previousEnd, emittedEnd)
            if capturedAt > silenceStart && capturedAt - silenceStart > AVAudioTime.hostTime(forSeconds: 0.0005) {
                let seconds = AVAudioTime.seconds(forHostTime: capturedAt - silenceStart)
                let missingFrames = Int((seconds * 48_000).rounded())
                pendingTime = silenceStart
                pending.append(Data(count: missingFrames * bytesPerFrame))
            }
        }
        lastCapturedStart = capturedAt
        let inputEnd = capturedAt + AVAudioTime.hostTime(forSeconds: Double(pcm.count / bytesPerFrame) / 48_000)
        lastCapturedEnd = max(lastCapturedEnd ?? 0, inputEnd)
        if !pending.isEmpty {
            let duration = AVAudioTime.hostTime(forSeconds: Double(pending.count / bytesPerFrame) / 48_000)
            let expected = pendingTime + duration
            if capturedAt > expected && capturedAt - expected > AVAudioTime.hostTime(forSeconds: 0.0005) {
                let seconds = AVAudioTime.seconds(forHostTime: capturedAt - expected)
                let missingFrames = Int((seconds * 48_000).rounded())
                pending.append(Data(count: missingFrames * bytesPerFrame))
            } else if capturedAt < expected && expected - capturedAt > AVAudioTime.hostTime(forSeconds: 0.005) {
                try flush(emit: emit)
            }
        }
        if pending.isEmpty { pendingTime = capturedAt }
        pending.append(pcm)
        while pending.count >= minimumFrames * bytesPerFrame {
            let length = min(pending.count, maximumFrames * bytesPerFrame)
            let end = pending.index(pending.startIndex, offsetBy: length)
            let packet = pending.subdata(in: pending.startIndex..<end)
            pending.removeSubrange(pending.startIndex..<end)
            let time = pendingTime
            pendingTime += AVAudioTime.hostTime(forSeconds: Double(length / bytesPerFrame) / 48_000)
            try deliver(packet, at: time, emit: emit)
        }
    }

    /// Preserve a partial tail after an idle capture, padding only the amount
    /// required by the existing receiver's minimum PCM block size.
    mutating func flush(emit: (Data, UInt64) -> Void) throws {
        guard !pending.isEmpty else { return }
        let minimumBytes = 128 * bytesPerFrame
        if pending.count < minimumBytes {
            pending.append(Data(count: minimumBytes - pending.count))
        }
        let packet = pending
        let time = pendingTime
        pending = Data()
        pendingTime = 0
        try deliver(packet, at: time, emit: emit)
    }

    private mutating func deliver(_ packet: Data, at time: UInt64, emit: (Data, UInt64) -> Void) throws {
        var effectiveTime = time
        if let expected = lastEmittedEnd {
            let tolerance = AVAudioTime.hostTime(forSeconds: 0.005)
            if time > expected && time - expected > tolerance {
                let gap = AVAudioTime.seconds(forHostTime: time - expected)
                // Real capture gaps are checked on input; cap catch-up work to
                // the overall playback buffer even when batching adds skew.
                guard gap <= 0.6 else { throw AudioPacketizerError.captureGapTooLong }
                var frames = Int((gap * 48_000).rounded())
                var silenceTime = expected
                while frames > 0 {
                    var chunk = min(frames, maximumFrames)
                    let remainder = frames - chunk
                    if remainder > 0 && remainder < 128 { chunk -= 128 - remainder }
                    emit(Data(count: chunk * bytesPerFrame), silenceTime)
                    silenceTime += AVAudioTime.hostTime(forSeconds: Double(chunk) / 48_000)
                    frames -= chunk
                }
                effectiveTime = silenceTime
            } else if time >= expected || expected - time <= tolerance {
                effectiveTime = expected
            }
        }
        lastEmittedEnd = effectiveTime + AVAudioTime.hostTime(forSeconds: Double(packet.count / bytesPerFrame) / 48_000)
        emit(packet, time)
    }
}
