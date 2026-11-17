import Foundation

/// Append-only, fsync'd JSONL capture file.
///
/// Invariant: `append(_:)` returns only once the lines are written AND `synchronize()` (fsync)
/// has succeeded. Callers must not send any command / ACK until it has returned without throwing.
/// The file is opened with O_APPEND|O_CREAT and is never truncated.
final class CaptureFile {
    struct Line {
        let kind: String     // "rx_raw" | "rx_frame" | "tx" | "session"
        let char: String     // short characteristic id ("0005"), "" for session lines
        let hex: String
        var note: String? = nil
    }

    let path: String
    private let handle: FileHandle
    private var closed = false
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "open(\(path)) failed: \(String(cString: strerror(errno)))"])
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Write all lines in one append, then fsync. Every line carries the same timestamp (they come
    /// from the same BLE notification).
    func append(_ lines: [Line], at date: Date = Date()) throws {
        guard !closed else { throw NSError(domain: "CaptureFile", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "capture file closed"]) }
        let t = iso.string(from: date)
        var out = ""
        for l in lines {
            out += "{\"t\":\"\(t)\",\"char\":\"\(l.char)\",\"kind\":\"\(l.kind)\",\"hex\":\"\(l.hex)\""
            if let note = l.note { out += ",\"note\":\"\(Self.escape(note))\"" }
            out += "}\n"
        }
        try handle.write(contentsOf: Data(out.utf8))
        try handle.synchronize()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.synchronize()
        try? handle.close()
    }

    private static func escape(_ s: String) -> String {
        var r = ""
        for c in s.unicodeScalars {
            switch c {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            default:
                if c.value < 0x20 { r += String(format: "\\u%04x", c.value) } else { r.unicodeScalars.append(c) }
            }
        }
        return r
    }
}
