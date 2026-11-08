import XCTest
import AVFoundation
import Darwin
@testable import SoundMashRelay

final class AudioPacketizerTests: XCTestCase {
    func testMixedCaptureSizesAreBoundedAndContinuous() throws {
        var packetizer = AudioPacketizer()
        let first = Data(repeating: 0x11, count: 1000 * 8)
        let large = Data(repeating: 0x22, count: 15_400 * 8)
        let remainder = Data(repeating: 0x33, count: 1008 * 8)
        var packets: [(Data, UInt64)] = []
        let start: UInt64 = 2_000_000_000
        try packetizer.append(first, capturedAt: start) { packets.append(($0, $1)) }
        XCTAssertTrue(packets.isEmpty)
        let secondTime = start + AVAudioTime.hostTime(forSeconds: 1000.0 / 48_000)
        let thirdTime = start + AVAudioTime.hostTime(forSeconds: 16_400.0 / 48_000)
        try packetizer.append(large, capturedAt: secondTime) { packets.append(($0, $1)) }
        try packetizer.append(remainder, capturedAt: thirdTime) { packets.append(($0, $1)) }
        XCTAssertEqual(packets.count, 5)
        XCTAssertTrue(packets.allSatisfy { (1024...4096).contains($0.0.count / 8) })
        XCTAssertEqual(packets.reduce(into: Data()) { $0.append($1.0) }, first + large + remainder)
        XCTAssertEqual(packets.first?.1, start)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        for index in 1..<packets.count {
            let elapsed = Double(packets[index].1 - packets[index - 1].1)
                * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
            XCTAssertEqual(elapsed, Double(packets[index - 1].0.count / 8) / 48_000, accuracy: 0.000001)
        }
    }

    func testShortGapProducesSilenceAndKeepsBothTimestamps() throws {
        var packetizer = AudioPacketizer()
        let first = Data(repeating: 0x11, count: 512 * 8)
        let second = Data(repeating: 0x22, count: 512 * 8)
        let start: UInt64 = 2_000_000_000
        let secondTime = start + AVAudioTime.hostTime(forSeconds: 512.0 / 48_000 + 0.05)
        var packets: [(Data, UInt64)] = []
        try packetizer.append(first, capturedAt: start) { packets.append(($0, $1)) }
        try packetizer.append(second, capturedAt: secondTime) { packets.append(($0, $1)) }
        try packetizer.flush { packets.append(($0, $1)) }
        XCTAssertEqual(packets.count, 1)
        let combined = packets[0].0
        XCTAssertEqual(combined.prefix(first.count), first)
        let gap = combined.dropFirst(first.count).prefix(2400 * 8)
        XCTAssertEqual(gap.count, 2400 * 8)
        XCTAssertTrue(gap.allSatisfy { $0 == 0 })
        XCTAssertEqual(combined.suffix(second.count), second)
        XCTAssertEqual(packets[0].1, start)
        XCTAssertFalse(packetizer.hasPending)
    }

    func testFourMillisecondGapRemainsAtItsOriginalPosition() throws {
        var packetizer = AudioPacketizer()
        let first = Data(repeating: 0x11, count: 512 * 8)
        let second = Data(repeating: 0x22, count: 512 * 8)
        let start: UInt64 = 2_000_000_000
        let secondTime = start + AVAudioTime.hostTime(forSeconds: 512.0 / 48_000 + 0.004)
        var packets: [(Data, UInt64)] = []
        try packetizer.append(first, capturedAt: start) { packets.append(($0, $1)) }
        try packetizer.append(second, capturedAt: secondTime) { packets.append(($0, $1)) }
        XCTAssertEqual(packets.count, 1)
        let combined = packets[0].0
        XCTAssertEqual(combined.prefix(first.count), first)
        XCTAssertEqual(combined.dropFirst(first.count).prefix(192 * 8), Data(count: 192 * 8))
        XCTAssertEqual(combined.suffix(second.count), second)
        XCTAssertEqual(packets[0].1, start)
    }

    func testFourMillisecondGapAfterEmittedPacketIsPreserved() throws {
        var packetizer = AudioPacketizer()
        let first = Data(repeating: 0x11, count: 1024 * 8)
        let second = Data(repeating: 0x22, count: 1024 * 8)
        let start: UInt64 = 2_000_000_000
        let previousEnd = start + AVAudioTime.hostTime(forSeconds: 1024.0 / 48_000)
        let secondTime = previousEnd + AVAudioTime.hostTime(forSeconds: 0.004)
        var packets: [(Data, UInt64)] = []
        try packetizer.append(first, capturedAt: start) { packets.append(($0, $1)) }
        try packetizer.append(second, capturedAt: secondTime) { packets.append(($0, $1)) }
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].0, first)
        XCTAssertEqual(packets[1].0.prefix(192 * 8), Data(count: 192 * 8))
        XCTAssertEqual(packets[1].0.suffix(second.count), second)
        XCTAssertEqual(packets[1].1, previousEnd)
    }

    func testShortTailIsFlushedWithBoundedSilencePadding() throws {
        var packetizer = AudioPacketizer()
        let tail = Data(repeating: 0x11, count: 16 * 8)
        var packets: [(Data, UInt64)] = []
        try packetizer.append(tail, capturedAt: 123) { packets.append(($0, $1)) }
        try packetizer.flush { packets.append(($0, $1)) }
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].0.count, 128 * 8)
        XCTAssertEqual(packets[0].0.prefix(tail.count), tail)
        XCTAssertTrue(packets[0].0.dropFirst(tail.count).allSatisfy { $0 == 0 })
        XCTAssertEqual(packets[0].1, 123)
        XCTAssertFalse(packetizer.hasPending)
    }

    func testRepeatedShortCaptureGapsRemainAlignedThroughTimeline() throws {
        var packetizer = AudioPacketizer()
        var timeline = AudioTimeline()
        let start: UInt64 = 2_000_000_000
        var realBlocks = 0
        for index in 0..<25 {
            let timestamp = start + AVAudioTime.hostTime(forSeconds: Double(index) * 0.04)
            try packetizer.append(Data(repeating: 0x11, count: 16 * 8), capturedAt: timestamp) { data, time in
                let (_, scheduled) = timeline.schedule(data, targetTime: time)
                let delta = scheduled > time ? scheduled - time : time - scheduled
                XCTAssertLessThan(AVAudioTime.seconds(forHostTime: delta), 0.003)
                if data.contains(0x11) { realBlocks += 1 }
            }
            try packetizer.flush { data, time in
                let (_, scheduled) = timeline.schedule(data, targetTime: time)
                let delta = scheduled > time ? scheduled - time : time - scheduled
                XCTAssertLessThan(AVAudioTime.seconds(forHostTime: delta), 0.003)
                if data.contains(0x11) { realBlocks += 1 }
            }
        }
        XCTAssertEqual(realBlocks, 25)
    }

    func testLongCaptureGapIsReportedInsteadOfInventingLongSilence() throws {
        var packetizer = AudioPacketizer()
        let samples = Data(repeating: 0x11, count: 128 * 8)
        let start: UInt64 = 2_000_000_000
        try packetizer.append(samples, capturedAt: start) { _, _ in }
        try packetizer.flush { _, _ in }
        let late = start + AVAudioTime.hostTime(forSeconds: 128.0 / 48_000 + 0.101)
        XCTAssertThrowsError(try packetizer.append(samples, capturedAt: late) { _, _ in })
    }

    func testRepeatedFourMillisecondGapsDoNotAccumulateInTimeline() throws {
        var packetizer = AudioPacketizer()
        var timeline = AudioTimeline()
        let start: UInt64 = 2_000_000_000
        let samples = Data(repeating: 0x11, count: 1024 * 8)
        var realBlocks = 0
        for index in 0..<40 {
            let time = start + AVAudioTime.hostTime(forSeconds: Double(index) * (1024.0 / 48_000 + 0.004))
            try packetizer.append(samples, capturedAt: time) { data, emitted in
                let (_, scheduled) = timeline.schedule(data, targetTime: emitted)
                if data.contains(0x11) {
                    let delta = scheduled > time ? scheduled - time : time - scheduled
                    XCTAssertLessThan(AVAudioTime.seconds(forHostTime: delta), 0.006)
                    realBlocks += 1
                }
            }
        }
        XCTAssertEqual(realBlocks, 40)
    }

    func testGapLimitUsesActualEndBeforeTailPadding() throws {
        var packetizer = AudioPacketizer()
        let samples = Data(repeating: 0x11, count: 16 * 8)
        let start: UInt64 = 2_000_000_000
        try packetizer.append(samples, capturedAt: start) { _, _ in }
        try packetizer.flush { _, _ in }
        let late = start + AVAudioTime.hostTime(forSeconds: 16.0 / 48_000 + 0.101)
        XCTAssertThrowsError(try packetizer.append(samples, capturedAt: late) { _, _ in })
    }

    func testBackwardsTimestampIsRejectedBeforeBatching() throws {
        var packetizer = AudioPacketizer()
        let samples = Data(repeating: 0x11, count: 16 * 8)
        let start: UInt64 = 2_000_000_000
        try packetizer.append(samples, capturedAt: start) { _, _ in }
        let backwards = start - AVAudioTime.hostTime(forSeconds: 0.001)
        XCTAssertThrowsError(try packetizer.append(samples, capturedAt: backwards) { _, _ in })
    }

    func testNormalCaptureClockDriftDoesNotStopTheStream() throws {
        let start: UInt64 = 2_000_000_000
        let samples = Data(repeating: 0, count: 1024 * 8)
        for ppm in [-100.0, 100.0] {
            var packetizer = AudioPacketizer()
            var timeline = AudioTimeline()
            for index in 0..<3000 {
                let elapsed = Double(index) * 1024.0 / 48_000 * (1 + ppm / 1_000_000)
                let timestamp = start + AVAudioTime.hostTime(forSeconds: elapsed)
                try packetizer.append(samples, capturedAt: timestamp) { data, time in
                    _ = timeline.schedule(data, targetTime: time)
                }
            }
        }
    }

    func testLegalGapAfterSmallOffsetIsAccepted() throws {
        var packetizer = AudioPacketizer()
        let start: UInt64 = 2_000_000_000
        let samples = Data(repeating: 0, count: 1024 * 8)
        let duration = 1024.0 / 48_000
        let second = start + AVAudioTime.hostTime(forSeconds: duration + 0.004)
        let third = second + AVAudioTime.hostTime(forSeconds: duration + 0.098)
        try packetizer.append(samples, capturedAt: start) { _, _ in }
        try packetizer.append(samples, capturedAt: second) { _, _ in }
        XCTAssertNoThrow(try packetizer.append(samples, capturedAt: third) { _, _ in })
    }

    func testLegalGapAfterMultipleBatchedOffsetsIsAccepted() throws {
        var packetizer = AudioPacketizer()
        let start: UInt64 = 2_000_000_000
        let first = Data(repeating: 0, count: 1024 * 8)
        let half = Data(repeating: 0, count: 512 * 8)
        let halfDuration = 512.0 / 48_000
        let second = start + AVAudioTime.hostTime(forSeconds: 1024.0 / 48_000 + 0.004)
        let third = second + AVAudioTime.hostTime(forSeconds: halfDuration + 0.004)
        let fourth = third + AVAudioTime.hostTime(forSeconds: halfDuration + 0.099)
        try packetizer.append(first, capturedAt: start) { _, _ in }
        try packetizer.append(half, capturedAt: second) { _, _ in }
        try packetizer.append(half, capturedAt: third) { _, _ in }
        XCTAssertNoThrow(try packetizer.append(first, capturedAt: fourth) { _, _ in })
    }
}
