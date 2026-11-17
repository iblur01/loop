import Foundation

/// Localized Today copy and reordered format arguments from the Today catalogue.
enum TodayL {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Today", comment: "")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: args)
    }
}
