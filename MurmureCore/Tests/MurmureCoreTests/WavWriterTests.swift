import AVFoundation
import XCTest
@testable import MurmureCore

final class WavWriterTests: XCTestCase {
    func testTwoSecondsOfSilenceProduceAReadableTwoSecondWav() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try WavWriter(directory: dir, format: format)

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000 // 1 s of silence
        try writer.append(buffer)
        try writer.append(buffer)

        let readBack = try AVAudioFile(forReading: writer.url)
        XCTAssertEqual(readBack.length, 32_000)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 16_000, accuracy: 1)
    }
}
