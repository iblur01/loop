import Foundation

// The iOS logger writes to Documents and stdout. A replay is a quiet CLI and must not modify
// the user's Documents directory; timings are measured externally instead.
enum PerfLog {
    static func reset(_ header: String) {}
    static func emit(_ message: String) {}
    static func ms(since from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }
}
