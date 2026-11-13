import XCTest
@testable import TokenMeter

final class IncrementalCacheTests: XCTestCase {
    func testPersistedSignaturesSurviveEpochPrecisionLoss() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeterSignatures-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl.zst")
        try Data("fixture".utf8).write(to: file)
        let cacheDir = dir.appendingPathComponent("cache")
        for index in 0..<32 {
            let date = Date(timeIntervalSince1970: 1_794_561_000 + Double(index) / 10_000_003)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            let signature = try XCTUnwrap(FileSignature(url: file))
            let cache = IncrementalCache<[Int]>(name: "test", directory: cacheDir)
            cache.set(file, signature: signature, data: [index])
            cache.save()
            let reloaded = IncrementalCache<[Int]>(name: "test", directory: cacheDir)
            XCTAssertFalse(reloaded.needsRescan(file), "epoch round-trip at \(index)")
            XCTAssertEqual(reloaded.get(file), [index])
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(0.001)], ofItemAtPath: file.path)
            XCTAssertTrue(reloaded.needsRescan(file))
        }
        let cache = IncrementalCache<[Int]>(name: "size", directory: cacheDir)
        cache.set(file, signature: try XCTUnwrap(FileSignature(url: file)), data: [1])
        try Data("fixture changed size".utf8).write(to: file)
        XCTAssertTrue(cache.needsRescan(file))
    }
}
