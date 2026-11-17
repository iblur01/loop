import Foundation

actor LocalDataStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadCache() async throws -> LoopCache {
        do {
            return try await load(LoopCache.self, from: cacheURL())
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        }
    }

    func saveCache(_ cache: LoopCache) async throws {
        try await save(cache, to: cacheURL())
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) async throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func cacheURL() -> URL {
        baseDirectory().appendingPathComponent("cache.json")
    }

    private func baseDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loop", isDirectory: true)
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory(),
            withIntermediateDirectories: true
        )
    }
}
