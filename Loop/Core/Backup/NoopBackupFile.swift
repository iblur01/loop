import Foundation
import ZIPFoundation

/// Extracts only Noop's database entry to a private temporary path. The archive's paths are never
/// used as output paths. The original selected file is neither modified nor removed.
enum NoopBackupFile {
    private static let maximumBytes: UInt64 = 4 * 1024 * 1024 * 1024

    enum ImportFileError: LocalizedError {
        case invalid, tooLarge, damaged, standaloneWAL
        var errorDescription: String? {
            switch self {
            case .invalid: return String(localized: "backup.noop.invalid", table: "Core")
            case .tooLarge: return String(localized: "backup.noop.large", table: "Core")
            case .damaged: return String(localized: "backup.noop.damaged", table: "Core")
            case .standaloneWAL: return String(localized: "backup.noop.wal", table: "Core")
            }
        }
    }

    /// The returned directory belongs to the caller and must be removed after import/cancellation.
    static func prepare(_ picked: URL) throws -> URL {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("noop-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let target = directory.appendingPathComponent("source.sqlite")
        do {
            let source = try FileHandle(forReadingFrom: picked)
            let magic = try source.read(upToCount: 20) ?? Data()
            try source.close()
            if magic.starts(with: Data("SQLite format 3\0".utf8)) {
                // A document picker copy may omit the adjacent -wal file, so checking for
                // that sidecar cannot establish that a WAL database is a complete snapshot.
                guard magic.count >= 20, magic[18] != 2, magic[19] != 2 else {
                    throw ImportFileError.standaloneWAL
                }
                let size = try picked.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, UInt64(size) <= maximumBytes else { throw ImportFileError.tooLarge }
                try fm.copyItem(at: picked, to: target)
            } else {
                let archive = try Archive(url: picked, accessMode: .read)
                let entries = archive.filter { $0.path == "noop-backup.sqlite" }
                guard entries.count == 1, let entry = entries.first, entry.type == .file else {
                    throw ImportFileError.invalid
                }
                guard entry.uncompressedSize > 0, entry.uncompressedSize <= maximumBytes else {
                    throw ImportFileError.tooLarge
                }
                guard fm.createFile(atPath: target.path, contents: nil) else { throw ImportFileError.invalid }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var written: UInt64 = 0
                let checksum = try archive.extract(entry) { data in
                    let count = UInt64(data.count)
                    guard count <= maximumBytes - written,
                          count <= entry.uncompressedSize - written else { throw ImportFileError.tooLarge }
                    written += count
                    try output.write(contentsOf: data)
                }
                guard written == entry.uncompressedSize, checksum == entry.checksum else {
                    throw ImportFileError.damaged
                }
            }
            return target
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
}
