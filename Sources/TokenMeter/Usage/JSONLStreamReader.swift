import Foundation
import CZstd

/// Bounded streaming reader. Never materializes a complete rollout or a
/// decompressed temporary file; zstd is linked into the app (no Homebrew/PATH).
struct JSONLStreamReader {
    enum ReadError: Error { case invalidArchive, truncatedArchive, oversizedLine }
    var chunkSize = 128 * 1024
    var maxLineBytes = 64 * 1024 * 1024

    func read(_ url: URL, onLine: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        func consume(_ bytes: Data) throws {
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
                guard pending.count + end - start <= maxLineBytes else { throw ReadError.oversizedLine }
                pending.append(contentsOf: bytes[start..<end])
                if end < bytes.endIndex {
                    if !pending.isEmpty { try autoreleasepool { try onLine(pending) } }
                    pending.removeAll(keepingCapacity: true)
                }
                start = end < bytes.endIndex ? end + 1 : end
            }
        }

        if url.lastPathComponent.hasSuffix(".jsonl.zst") {
            guard let stream = ZSTD_createDStream() else { throw ReadError.invalidArchive }
            defer { ZSTD_freeDStream(stream) }
            guard ZSTD_isError(ZSTD_initDStream(stream)) == 0,
                  ZSTD_isError(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 27)) == 0 else {
                throw ReadError.invalidArchive
            }
            var output = [UInt8](repeating: 0, count: chunkSize)
            var remaining = 1
            var readAny = false
            // Scope the file read itself, not only JSON parsing: FileHandle/Data
            // bridging can otherwise accumulate autoreleased buffers on an actor.
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return false }
                readAny = true
                try data.withUnsafeBytes { inputBytes in
                    var input = ZSTD_inBuffer(src: inputBytes.baseAddress, size: data.count, pos: 0)
                    // A full output buffer may require draining even after input is consumed.
                    var drain = true
                    while input.pos < input.size || drain {
                        let before = input.pos
                        var written = 0
                        remaining = output.withUnsafeMutableBytes { buffer in
                            var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                            let result = ZSTD_decompressStream(stream, &out, &input)
                            written = out.pos
                            return result
                        }
                        guard ZSTD_isError(remaining) == 0 else { throw ReadError.invalidArchive }
                        if written > 0 { try consume(Data(output.prefix(written))) }
                        drain = written == output.count && remaining != 0
                        if input.pos == before && written == 0 { break }
                    }
                }
                return true
            }) {}
            guard readAny, remaining == 0 else { throw ReadError.truncatedArchive }
        } else {
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return false }
                try consume(data)
                return true
            }) {}
        }
        if !pending.isEmpty { try autoreleasepool { try onLine(pending) } }
    }
}
