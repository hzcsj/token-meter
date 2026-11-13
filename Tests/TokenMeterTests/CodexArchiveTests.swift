import XCTest
@testable import TokenMeter

final class CodexArchiveTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeterArchive-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Valid zstd single-segment frame with raw blocks, generated without a runtime compressor.
    private func frame(_ data: Data) -> Data {
        var result = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        let size = UInt32(data.count)
        for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: size >> shift)) }
        var start = 0
        repeat {
            let end = min(start + 128 * 1024, data.count)
            let header = ((end - start) << 3) | (end == data.count ? 1 : 0)
            for shift in stride(from: 0, to: 24, by: 8) { result.append(UInt8(truncatingIfNeeded: header >> shift)) }
            result.append(data[start..<end])
            start = end
        } while start < data.count
        return result
    }

    private var rollout: Data {
        Data("""
        {"type":"session_meta","payload":{"id":"test-thread"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-terra","service_tier":"fast"}}
        {"timestamp":"2026-10-26T12:00:00.001Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":40000,"cache_write_input_tokens":20000,"output_tokens":10000,"reasoning_output_tokens":5000,"total_tokens":110000}}}}
        {"type":"turn_context","payload":{"model":"gpt-6-astra","service_tier":"default"}}
        {"timestamp":"2026-10-27T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        """.utf8)
    }

    func testPlainAndZstdMatchWithTinyChunksUTF8CRLFAndFinalLine() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let text = Data("{\"中文\":\"🙂\"}\r\n\nlast".utf8)
        var expected: [Data] = []
        for ext in ["jsonl", "jsonl.zst"] {
            let url = dir.appendingPathComponent("rollout.\(ext)")
            try (ext == "jsonl" ? text : frame(text)).write(to: url)
            var lines: [Data] = []
            try JSONLStreamReader(chunkSize: 3).read(url) { lines.append($0) }
            XCTAssertEqual(lines.count, 2)
            if expected.isEmpty { expected = lines } else { XCTAssertEqual(lines, expected) }
        }
    }

    func testConcatenatedFramesAndLargeLineRemainStreaming() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout.jsonl.zst")
        let text = Data((String(repeating: "x", count: 300_000) + "\n").utf8)
        try (frame(text) + frame(Data("tail".utf8))).write(to: url)
        var lengths: [Int] = []
        try JSONLStreamReader(chunkSize: 1024).read(url) { lengths.append($0.count) }
        XCTAssertEqual(lengths, [300_000, 4])
        XCTAssertThrowsError(try JSONLStreamReader(maxLineBytes: 100).read(url) { _ in })
    }

    func testEmptyCorruptAndTruncatedArchivesFail() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout.jsonl.zst")
        for data in [Data(), Data("not zstd".utf8), Data(frame(rollout).dropLast())] {
            try data.write(to: url)
            XCTAssertThrowsError(try JSONLStreamReader().read(url) { _ in })
        }
        try frame(Data()).write(to: url)
        XCTAssertNoThrow(try JSONLStreamReader().read(url) { _ in XCTFail("Empty frame") })
    }

    func testCompressedBlockChecksumAndSmallOutputBuffer() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout.jsonl.zst")
        // zstd CLI fixture of 100 identical lines, with compressed blocks and checksum.
        var data = Data(base64Encoded: "KLUv/QRYLQEA6GhlbGxvIHpzdGQgY29tcHJlc3NlZCBibG9ja3MKAQDRDPjKCQ8K1pI=")!
        try data.write(to: url)
        var lines = 0
        try JSONLStreamReader(chunkSize: 7).read(url) {
            XCTAssertEqual(String(decoding: $0, as: UTF8.self), "hello zstd compressed blocks")
            lines += 1
        }
        XCTAssertEqual(lines, 100)
        data[data.count - 1] ^= 1
        try data.write(to: url)
        XCTAssertThrowsError(try JSONLStreamReader().read(url) { _ in })
    }

    func testArchivalOverlapAndWarmCacheDoNotLoseOrDoubleCount() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("sessions")
        let archive = dir.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let plain = live.appendingPathComponent("rollout-test.jsonl")
        let compressed = archive.appendingPathComponent("rollout-test.jsonl.zst")
        try rollout.write(to: plain)
        try frame(rollout).write(to: compressed)
        let cacheDir = dir.appendingPathComponent("cache")
        let scanner = CodexUsageScanner(codexDir: dir, cacheDirectory: cacheDir)
        let first = try XCTUnwrap(scanner.scan().summary)
        XCTAssertEqual(first.allTimeTotal.tokens, 110_120)
        XCTAssertEqual(first.allTimeTotal.messageCount, 2)
        XCTAssertEqual(first.allTimeTotal.costCNY, 1.652, accuracy: 0.000001)
        XCTAssertEqual(first.weekTotal.tokens, 0)
        try FileManager.default.removeItem(at: plain)
        XCTAssertEqual(scanner.scan().summary, first)
        let cacheFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cacheDir,
            includingPropertiesForKeys: nil).first)
        let mtime = try cacheFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let restarted = CodexUsageScanner(codexDir: dir, cacheDirectory: cacheDir)
        XCTAssertEqual(restarted.scan().summary, first)
        XCTAssertEqual(try cacheFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mtime)
        // A read failure retains the last valid entry and retries when repaired.
        try Data(frame(rollout).dropLast()).write(to: compressed)
        XCTAssertEqual(restarted.scan().summary, first)
        try frame(rollout + Data("\n".utf8) + rollout).write(to: compressed)
        XCTAssertEqual(restarted.scan().summary?.allTimeTotal.tokens, 220_240)
    }

    func testFailedColdScanDoesNotPersistEmptyArchive() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let url = archive.appendingPathComponent("rollout.jsonl.zst")
        try Data(frame(rollout).dropLast()).write(to: url)
        let scanner = CodexUsageScanner(codexDir: dir, cacheDirectory: dir.appendingPathComponent("cache"))
        XCTAssertNil(scanner.scan().summary)
        try frame(rollout).write(to: url)
        XCTAssertEqual(scanner.scan().summary?.allTimeTotal.tokens, 110_120)
    }

    func testLocalArchiveRecoveryWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKEN_METER_VERIFY_LOCAL_USAGE"] == "1" else {
            throw XCTSkip("Opt-in read-only local rollout verification")
        }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = CodexUsageScanner(cacheDirectory: dir)
        let start = Date()
        let first = try XCTUnwrap(scanner.scan().summary)
        print("Local verification: tokens=\(first.allTimeTotal.tokens), records=\(first.allTimeTotal.messageCount), coldSeconds=\(Date().timeIntervalSince(start))")
        XCTAssertGreaterThan(first.allTimeTotal.tokens, 0)
        let warmStart = Date()
        let warm = try XCTUnwrap(scanner.scan().summary)
        print("Local warm scan seconds=\(Date().timeIntervalSince(warmStart))")
        XCTAssertGreaterThanOrEqual(warm.allTimeTotal.tokens, first.allTimeTotal.tokens)
    }
}
