import Foundation

struct FileSignature: Codable, Equatable {
    let mtime: Date
    let size: UInt64

    init?(url: URL) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? UInt64 else {
                return nil
            }
            self.mtime = mtime
            self.size = size
        } catch {
            return nil
        }
    }
}

struct CacheEntry<T: Codable>: Codable {
    let signature: FileSignature
    let data: T
}

final class IncrementalCache<T: Codable> {
    private let cacheFile: URL
    private var cache: [String: CacheEntry<T>] = [:]
    private var dirty = false

    init(name: String, directory: URL? = nil) {
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDir = directory ?? cacheBase.appendingPathComponent("token-meter", isDirectory: true)
        self.cacheFile = cacheDir.appendingPathComponent("\(name).json")
        load()
    }

    func needsRescan(_ url: URL) -> Bool {
        guard let signature = FileSignature(url: url) else {
            return true
        }

        guard let entry = cache[url.path] else {
            return true
        }

        return entry.signature != signature
    }

    func get(_ url: URL) -> T? {
        cache[url.path]?.data
    }

    func set(_ url: URL, signature: FileSignature, data: T) {
        cache[url.path] = CacheEntry(signature: signature, data: data)
        dirty = true
    }

    func cleanup(validPaths: Set<String>) {
        let obsolete = cache.keys.filter { !validPaths.contains($0) }
        guard !obsolete.isEmpty else { return }
        for key in obsolete { cache.removeValue(forKey: key) }
        dirty = true
    }

    func save() {
        guard dirty else { return }
        let cacheDir = cacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        if let data = try? encoder.encode(cache) {
            do {
                try data.write(to: cacheFile, options: .atomic)
                dirty = false
            } catch { /* Retry on the next scan; keep the last on-disk cache. */ }
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: cacheFile.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: cacheFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            cache = try decoder.decode([String: CacheEntry<T>].self, from: data)
        } catch {
            cache = [:]
        }
    }
}
