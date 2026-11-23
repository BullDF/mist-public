import AVFoundation
import ImageIO
import XCTest
@testable import Phi

final class BrowserAgentRecordingWriterTests: XCTestCase {
    private let size = CGSize(width: 1600, height: 900)

    func testWriterKeepsPixelDimensionsAndStaticTailAndReturnsFourStills() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("demo.mp4")
        let video = try await writeRecording(to: path, count: 20)
        XCTAssertEqual(video.url, path)
        XCTAssertGreaterThan(video.bytes, 0)
        XCTAssertEqual(video.frameCount, 20)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["demo.mp4"])

        let asset = AVURLAsset(url: path)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let dimensions = try await track.load(.naturalSize)
        XCTAssertEqual(dimensions, size)
        let result = try await video.result(endedBy: .stopped)
        XCTAssertEqual(result.duration, 3, accuracy: 0.1)
        XCTAssertEqual(result.stills.count, 4)
        let times = result.stills.map(\.at)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count)
        let maximum = BrowserAgentScreenshotGeometry.modelSize(for: size)
        for still in result.stills {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(still.data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertLessThanOrEqual(CGFloat(image.width), maximum.width)
            XCTAssertLessThanOrEqual(CGFloat(image.height), maximum.height)
        }
    }

    func testWriterRefusesInterveningDestinationAndCleansUpTemporaryFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("existing.mp4")
        let contents = Data("existing".utf8)
        do {
            _ = try await writeRecording(to: path, count: 1) { try contents.write(to: path) }
            XCTFail("The recording replaced an existing file")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That file exists. Pass overwrite: true or choose another path.")
        }
        XCTAssertEqual(try Data(contentsOf: path), contents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.mp4"])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func writeRecording(to url: URL, count: Int, beforeFinish: @escaping @Sendable () throws -> Void = {}) async throws -> BrowserAgentRecordingVideo {
        let queue = DispatchQueue(label: "mist.recording-writer-test")
        let size = self.size
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let writer = try BrowserAgentRecordingWriter(destination: url, overwrite: false, size: size, queue: queue)
                    do {
                        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                        for index in 0..<count {
                            context.setFillColor(CGColor(red: CGFloat(index) / 20, green: 0, blue: 1, alpha: 1))
                            context.fill(CGRect(origin: .zero, size: size))
                            let image = try XCTUnwrap(context.makeImage())
                            let time = CMTime(value: Int64(index), timescale: 10)
                            let deadline = DispatchTime.now() + .seconds(2)
                            while try !writer.append(image, at: time) {
                                guard DispatchTime.now() < deadline else { throw CocoaError(.fileWriteUnknown) }
                                Thread.sleep(forTimeInterval: 0.01)
                            }
                        }
                        try beforeFinish()
                        writer.finish(at: CMTime(value: 3, timescale: 1)) { continuation.resume(with: $0) }
                    } catch {
                        writer.cancel()
                        throw error
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
