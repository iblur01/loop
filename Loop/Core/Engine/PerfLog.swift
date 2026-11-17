import Foundation
import os

// MARK: - PerfLog
//
// Traceur de performance on-device pour le pipeline de recalcul. Chaque ligne part vers
// TROIS sorties pour rester capturable par un agent sans Xcode :
//   1. `os.Logger` (subsystem loop.engine / category perf) — visible dans Console.app / `log`.
//   2. `print()` vers stdout — capturé en direct par `devicectl device process launch --console`.
//   3. Un fichier `Documents/perf.log` — récupérable après coup via
//      `devicectl device copy from --domain-type appDataContainer`.
//
// Toutes les lignes sont préfixées `[PERF]` pour un grep trivial. `reset()` ouvre une nouvelle
// session de mesure (tronque le fichier) ; `emit()` ajoute une ligne horodatée (offset depuis
// le dernier reset, en secondes).
enum PerfLog {
    private static let log = Logger(subsystem: "loop.engine", category: "perf")
    private static let lock = NSLock()
    private static var sessionStart = Date()

    private static let fileURL: URL? = {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("perf.log")
    }()

    /// Démarre une nouvelle session de mesure : remet l'horloge relative à zéro et tronque le
    /// fichier avec une ligne d'en-tête. Appelé en tête de `computeCore` / `computeExpress`.
    static func reset(_ header: String) {
        lock.lock()
        sessionStart = Date()
        if let url = fileURL {
            try? "".data(using: .utf8)?.write(to: url)
        }
        lock.unlock()
        emit(header)
    }

    /// Ajoute une ligne `[PERF] +<offset>s <message>` aux trois sorties.
    static func emit(_ message: String) {
        let offset = Date().timeIntervalSince(sessionStart)
        let line = String(format: "[PERF] +%7.3fs %@", offset, message)
        log.info("\(message, privacy: .public)")
        print(line)
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Millisecondes écoulées depuis `from`, arrondies — sucre pour les lignes de mesure.
    static func ms(since from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }
}
