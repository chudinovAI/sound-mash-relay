import Foundation
import Darwin

/// Schedules contiguous PCM and slews towards a target host time. The fractional
/// source position and the last stereo sample survive block boundaries, so rate
/// changes do not reset interpolation phase at every packet.
struct AudioTimeline {
    private let ticksPerSecond: Double
    private var nextTime: UInt64 = 0
    private var filteredError = 0.0
    private var position = 1.0
    private var previousLeft: Float = 0
    private var previousRight: Float = 0
    private var hasPrevious = false

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    }

    mutating func schedule(_ input: Data, targetTime: UInt64) -> (Data, UInt64) {
        precondition(input.count >= 32 * 8 && input.count % 8 == 0)
        if nextTime == 0 { nextTime = targetTime }
        let error = (Double(nextTime) - Double(targetTime)) / ticksPerSecond
        filteredError += 0.02 * (error - filteredError)
        let rate = abs(filteredError) > 0.002 ? min(0.02, abs(filteredError) * 0.1) : 0
        let step = 1 + (filteredError > 0 ? rate : -rate)
        let frames = input.count / 8
        var output = Data(count: (Int(ceil(Double(frames) / 0.98)) + 2) * 8)
        var produced = 0
        input.withUnsafeBytes { source in
            if !hasPrevious {
                previousLeft = source.loadUnaligned(fromByteOffset: 0, as: Float.self)
                previousRight = source.loadUnaligned(fromByteOffset: 4, as: Float.self)
                hasPrevious = true
            }
            output.withUnsafeMutableBytes { destination in
                while position < Double(frames) {
                    let index = Int(position)
                    let fraction = Float(position - Double(index))
                    let leftA = index == 0 ? previousLeft : source.loadUnaligned(fromByteOffset: (index - 1) * 8, as: Float.self)
                    let rightA = index == 0 ? previousRight : source.loadUnaligned(fromByteOffset: (index - 1) * 8 + 4, as: Float.self)
                    let leftB = source.loadUnaligned(fromByteOffset: index * 8, as: Float.self)
                    let rightB = source.loadUnaligned(fromByteOffset: index * 8 + 4, as: Float.self)
                    destination.storeBytes(of: leftA + (leftB - leftA) * fraction, toByteOffset: produced * 8, as: Float.self)
                    destination.storeBytes(of: rightA + (rightB - rightA) * fraction, toByteOffset: produced * 8 + 4, as: Float.self)
                    produced += 1
                    position += step
                }
            }
            previousLeft = source.loadUnaligned(fromByteOffset: (frames - 1) * 8, as: Float.self)
            previousRight = source.loadUnaligned(fromByteOffset: (frames - 1) * 8 + 4, as: Float.self)
        }
        position -= Double(frames)
        output.removeSubrange((produced * 8)..<output.count)
        let time = nextTime
        nextTime += UInt64(Double(produced) * ticksPerSecond / 48_000)
        return (output, time)
    }
}

private enum CaptureTimestampError: LocalizedError {
    case timeWentBackwards
    case captureGapTooLong
    case converterBacklog

    var errorDescription: String? {
        switch self {
        case .timeWentBackwards: return "Временные метки захвата звука пошли назад."
        case .captureGapTooLong: return "Захват звука прервался более чем на 100 мс."
        case .converterBacklog: return "Преобразователь звука накопил слишком много входных блоков."
        }
    }
}

/// Associates output frames with their original capture block, including
/// input buffered by a converter that temporarily produced no output.
struct CaptureTimestamp {
    private struct Segment {
        let inputStart: UInt64
        let outputEnd: UInt64
        let capturedAt: UInt64
    }

    private let inputRate: Double
    private let outputRate: Double
    private let ticksPerSecond: Double
    private var inputFramesSeen: UInt64 = 0
    private var outputFramesProduced: UInt64 = 0
    private var lastInputStart: UInt64?
    private var lastInputEnd: UInt64?
    private var segments: [Segment] = []

    init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    }

    mutating func map(capturedAt: UInt64, inputFrames: Int, outputFrames: Int,
                      emit: (Int, Int, UInt64) throws -> Void) throws {
        if let previous = lastInputStart, capturedAt < previous {
            throw CaptureTimestampError.timeWentBackwards
        }
        if let end = lastInputEnd, capturedAt > end,
           Double(capturedAt - end) / ticksPerSecond > 0.1 {
            throw CaptureTimestampError.captureGapTooLong
        }
        lastInputStart = capturedAt
        let inputEndTime = capturedAt + UInt64(Double(inputFrames) / inputRate * ticksPerSecond)
        lastInputEnd = max(lastInputEnd ?? 0, inputEndTime)
        let inputStart = inputFramesSeen
        inputFramesSeen += UInt64(inputFrames)
        let outputEnd = UInt64(ceil(Double(inputFramesSeen) * outputRate / inputRate))
        segments.append(Segment(inputStart: inputStart, outputEnd: outputEnd, capturedAt: capturedAt))
        guard segments.count <= 512 else { throw CaptureTimestampError.converterBacklog }

        var offset = 0
        while offset < outputFrames {
            while segments.count > 1 && outputFramesProduced >= segments[0].outputEnd {
                segments.removeFirst()
            }
            let segment = segments[0]
            let available = outputFramesProduced < segment.outputEnd
                ? min(UInt64(outputFrames - offset), segment.outputEnd - outputFramesProduced)
                : UInt64(outputFrames - offset)
            let timeOffset = Double(outputFramesProduced) / outputRate - Double(segment.inputStart) / inputRate
            let firstTime = UInt64(max(0, Double(segment.capturedAt) + timeOffset * ticksPerSecond))
            try emit(offset, Int(available), firstTime)
            offset += Int(available)
            outputFramesProduced += available
        }
    }
}
