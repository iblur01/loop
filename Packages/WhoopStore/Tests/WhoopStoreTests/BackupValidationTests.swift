import Foundation
import XCTest
@testable import WhoopStore

final class BackupValidationTests: XCTestCase {
    private func makePackage() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = folder.appendingPathComponent("source.sqlite")
        let store = try await WhoopStore(path: db.path)
        try await store.upsertDevice(id: "test", mac: nil, name: nil)
        try await store.checkpoint()
        try FileManager.default.copyItem(at: db, to: folder.appendingPathComponent("whoop.sqlite"))
        try Data("{\"schemaVersion\": 8}".utf8).write(to: folder.appendingPathComponent("meta.json"))
        return folder
    }

    func testValidBackupPassesReadOnlyChecks() async throws {
        let folder = try await makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try BackupValidation.validate(package: folder)
        XCTAssertEqual(result.schemaVersion, 8)
        XCTAssertFalse(result.hasCache)
    }

    func testCorruptDatabaseRejected() async throws {
        let folder = try await makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not a database".utf8).write(to: folder.appendingPathComponent("whoop.sqlite"))
        XCTAssertThrowsError(try BackupValidation.validate(package: folder))
    }

    func testUnsupportedVersionAndInvalidCacheRejected() async throws {
        let folder = try await makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = folder.appendingPathComponent("meta.json")
        try Data("{\"schemaVersion\": 999}".utf8).write(to: meta)
        XCTAssertThrowsError(try BackupValidation.validate(package: folder))
        try Data("{\"schemaVersion\": 8}".utf8).write(to: meta)
        try Data("invalid".utf8).write(to: folder.appendingPathComponent("cache.json"))
        XCTAssertThrowsError(try BackupValidation.validate(package: folder))
    }
}
