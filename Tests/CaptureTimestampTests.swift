import XCTest
import AVFoundation
@testable import SoundMashRelay

final class CaptureTimestampTests: XCTestCase {
    func testBufferedOutputRetainsEachPhysicalCaptureTime() throws {
        var clock = CaptureTimestamp(inputRate: 44_100, outputRate: 48_000)
        let start: UInt64 = 2_000_000_000
        var slices: [(Int, Int, UInt64)] = []
        try clock.map(capturedAt: start, inputFrames: 441, outputFrames: 0) { slices.append(($0, $1, $2)) }
        let second = start + AVAudioTime.hostTime(forSeconds: 0.1)
        try clock.map(capturedAt: second, inputFrames: 441, outputFrames: 0) { slices.append(($0, $1, $2)) }
        let third = start + AVAudioTime.hostTime(forSeconds: 0.2)
        try clock.map(capturedAt: third, inputFrames: 441, outputFrames: 1440) { slices.append(($0, $1, $2)) }
        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(slices.map { $0.0 }, [0, 480, 960])
        XCTAssertEqual(slices.map { $0.1 }, [480, 480, 480])
        XCTAssertEqual(slices.map { $0.2 }, [start, second, third])

        var packetizer = AudioPacketizer()
        var timeline = AudioTimeline()
        var reconstructed = Data()
        for (_, count, time) in slices {
            try packetizer.append(Data(repeating: 0x11, count: count * 8), capturedAt: time) { data, target in
                _ = timeline.schedule(data, targetTime: target)
                reconstructed.append(data)
            }
        }
        try packetizer.flush { data, target in
            _ = timeline.schedule(data, targetTime: target)
            reconstructed.append(data)
        }
        let audio = Data(repeating: 0x11, count: 480 * 8)
        let silence = Data(count: 4320 * 8)
        XCTAssertEqual(reconstructed, audio + silence + audio + silence + audio)
    }

    func testPhysicalGapIsCheckedEvenWithoutConvertedOutput() throws {
        var clock = CaptureTimestamp(inputRate: 48_000, outputRate: 48_000)
        let start: UInt64 = 2_000_000_000
        try clock.map(capturedAt: start, inputFrames: 480, outputFrames: 0) { _, _, _ in }
        let late = start + AVAudioTime.hostTime(forSeconds: 0.111)
        XCTAssertThrowsError(try clock.map(capturedAt: late, inputFrames: 480, outputFrames: 0) { _, _, _ in })
    }
}
