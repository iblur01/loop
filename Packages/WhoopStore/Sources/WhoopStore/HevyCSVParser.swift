import Foundation

// MARK: - Export CSV Hevy (pur, sans I/O)
//
// Une ligne par SÉRIE ; une séance = les lignes qui partagent (title, start_time, end_time).
// Les dates sont du texte français sans fuseau (« 12 nov. 2026, 12:22 », « 1 mars 2026 ») :
// elles sont lues dans le fuseau fourni (celui de l'appareil par défaut). Une ligne illisible
// (date inconnue, fin ≤ début, colonnes manquantes) est comptée et ignorée, jamais fatale.

/// Une séance reconstituée depuis l'export.
public struct HevySession: Equatable, Sendable {
    /// Titre tel quel (emojis compris).
    public let title: String
    public let start: Date
    public let end: Date
    /// Séries hors échauffement (normal, dropset, failure…).
    public let workingSetCount: Int
    /// Séries `warmup`, comptées à part.
    public let warmupSetCount: Int
    /// Σ poids × reps des séries hors échauffement, en kg (séries sans poids ou sans reps : 0).
    public let volumeKg: Double
    /// Σ poids × reps des séries d'échauffement, en kg.
    public let warmupVolumeKg: Double

    public init(title: String, start: Date, end: Date, workingSetCount: Int, warmupSetCount: Int,
                volumeKg: Double, warmupVolumeKg: Double) {
        self.title = title; self.start = start; self.end = end
        self.workingSetCount = workingSetCount; self.warmupSetCount = warmupSetCount
        self.volumeKg = volumeKg; self.warmupVolumeKg = warmupVolumeKg
    }

    public var setCount: Int { workingSetCount + warmupSetCount }
}

public struct HevyCSVParseResult: Equatable, Sendable {
    /// Séances dans l'ordre de première apparition dans le fichier.
    public let sessions: [HevySession]
    /// Lignes de données ignorées (date illisible, fin ≤ début, champs obligatoires manquants).
    public let skippedRows: Int
}

public enum HevyCSVParser {
    public enum ParseError: Error, Equatable {
        /// Fichier vide ou sans ligne d'en-tête.
        case empty
        /// En-têtes obligatoires absents (pas un export Hevy).
        case missingColumns([String])
    }

    static let requiredColumns = ["title", "start_time", "end_time"]

    /// Analyse le texte complet d'un export. BOM UTF-8, CRLF / LF / CR, champs entre guillemets
    /// (virgules, guillemets doublés et retours à la ligne inclus) sont gérés.
    public static func parse(_ text: String, timeZone: TimeZone = .current) throws -> HevyCSVParseResult {
        var rows = records(text)
        guard !rows.isEmpty else { throw ParseError.empty }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() where index[name] == nil { index[name] = i }
        let missing = requiredColumns.filter { index[$0] == nil }
        guard missing.isEmpty else { throw ParseError.missingColumns(missing) }

        struct Key: Hashable { let title: String; let start: String; let end: String }
        struct Acc { var start: Date; var end: Date; var working = 0; var warmup = 0; var volume = 0.0; var warmupVolume = 0.0 }
        var order: [Key] = []
        var groups: [Key: Acc] = [:]
        var invalidKeys: Set<Key> = []
        var skipped = 0

        func field(_ row: [String], _ name: String) -> String? {
            guard let i = index[name], i < row.count else { return nil }
            return row[i]
        }

        for row in rows {
            // Ligne vide (fin de fichier, saut de ligne double) : ni séance ni erreur.
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            guard let title = field(row, "title"), let startText = field(row, "start_time"),
                  let endText = field(row, "end_time") else { skipped += 1; continue }
            let key = Key(title: title, start: startText, end: endText)
            if invalidKeys.contains(key) { skipped += 1; continue }
            if groups[key] == nil {
                guard let start = date(startText, timeZone: timeZone),
                      let end = date(endText, timeZone: timeZone), end > start else {
                    invalidKeys.insert(key); skipped += 1; continue
                }
                groups[key] = Acc(start: start, end: end)
                order.append(key)
            }
            let isWarmup = field(row, "set_type")?.trimmingCharacters(in: .whitespaces).lowercased() == "warmup"
            let load = (number(field(row, "weight_kg")) ?? 0) * (number(field(row, "reps")) ?? 0)
            if isWarmup {
                groups[key]!.warmup += 1
                groups[key]!.warmupVolume += load
            } else {
                groups[key]!.working += 1
                groups[key]!.volume += load
            }
        }

        let sessions = order.compactMap { key -> HevySession? in
            guard let a = groups[key] else { return nil }
            return HevySession(title: key.title, start: a.start, end: a.end, workingSetCount: a.working,
                               warmupSetCount: a.warmup, volumeKg: a.volume, warmupVolumeKg: a.warmupVolume)
        }
        return HevyCSVParseResult(sessions: sessions, skippedRows: skipped)
    }

    /// Texte du fichier : UTF-8, sinon Windows-1252 (export ré-enregistré par un tableur).
    /// nil si aucun des deux ne convient.
    public static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    // MARK: - Dates françaises

    /// Mois français (formes abrégées Hevy et formes pleines), clé sans accent ni point final.
    static let months: [String: Int] = [
        "janv": 1, "janvier": 1,
        "fevr": 2, "fev": 2, "fevrier": 2,
        "mars": 3,
        "avr": 4, "avril": 4,
        "mai": 5,
        "juin": 6,
        "juil": 7, "juillet": 7,
        "aout": 8,
        "sept": 9, "septembre": 9,
        "oct": 10, "octobre": 10,
        "nov": 11, "novembre": 11,
        "dec": 12, "decembre": 12
    ]

    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(\d{1,2})\s+([^\s\d,]+)\s+(\d{4})(?:\s*,?\s*(\d{1,2})\s*[:h]\s*(\d{2}))?$"#)

    /// « 12 nov. 2026, 12:22 », « 1 févr. 2026 09:05 », « 1 mars 2026 » (minuit), virgule finale
    /// tolérée. Heure locale de `timeZone` ; nil si la date n'existe pas (31 févr., 25:00…).
    public static func date(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "," || last.isWhitespace { text.removeLast() }
        let ns = text as NSString
        guard let m = datePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let monthKey = (group(2) ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let day = group(1).flatMap(Int.init), let year = group(3).flatMap(Int.init),
              let month = months[monthKey] else { return nil }
        let hour = group(4).flatMap(Int.init) ?? 0
        let minute = group(5).flatMap(Int.init) ?? 0
        guard (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = cal.date(from: comps) else { return nil }
        // Refuse les dates que le calendrier « reporterait » (31 févr. → 3 mars).
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    // MARK: - CSV

    /// Nombre décimal ; accepte la virgule décimale. nil si vide ou illisible.
    static func number(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let v = Double(raw.replacingOccurrences(of: ",", with: ".")), v.isFinite else { return nil }
        return v
    }

    /// Découpe RFC 4180 tolérante, au niveau des scalaires Unicode (un CRLF n'est pas un seul
    /// « caractère » ici, et les emojis traversent intacts).
    static func records(_ text: String) -> [[String]] {
        var scalars = Substring(text).unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var sawAny = false
        var it = scalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
        func endRow() { endField(); rows.append(row); row = [] }

        while let c = pending ?? it.next() {
            pending = nil
            sawAny = true
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": endField()
            case "\r":
                if let n = it.next(), n != "\n" { pending = n }
                endRow()
            case "\n": endRow()
            default: field.append(c)
            }
        }
        if sawAny && (!field.isEmpty || !row.isEmpty) { endRow() }
        return rows
    }
}
