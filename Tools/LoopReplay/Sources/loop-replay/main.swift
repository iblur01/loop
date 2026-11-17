import Foundation
import ReplayCore

let usage = """
Usage: loop-replay BACKUP.loopbackup --from UNIX --to UNIX --revision LABEL
       [--device ID] [--timezone IANA] [--resting-hr BPM --max-hr BPM]

Runs LoopStrapEngine on the specified half-open interval (maximum 48 hours),
using a private temporary copy. JSON is written to stdout. Do not commit output:
it contains sensitive health information. A quiescent backup is required.
"""

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] || args == ["-h"] { print(usage); exit(0) }
    guard let path = args.first, !path.hasPrefix("--"), args.count % 2 == 1 else { throw ReplayError.invalid(usage) }
    var values: [String: String] = [:]
    let known = Set(["--from", "--to", "--revision", "--device", "--timezone", "--resting-hr", "--max-hr"])
    var i = 1
    while i < args.count {
        let key = args[i]
        guard known.contains(key), values[key] == nil else { throw ReplayError.invalid("Unknown or repeated option: \(key)") }
        values[key] = args[i + 1]; i += 2
    }
    guard let f = values["--from"].flatMap(Int64.init), let t = values["--to"].flatMap(Int64.init),
          let revision = values["--revision"] else { throw ReplayError.invalid(usage) }
    let rest = values["--resting-hr"].flatMap(Double.init)
    let maximum = values["--max-hr"].flatMap(Double.init)
    if (values["--resting-hr"] != nil && rest == nil) || (values["--max-hr"] != nil && maximum == nil) {
        throw ReplayError.invalid("Heart rate options must be numbers")
    }
    let report = try replay(ReplayOptions(backup: URL(fileURLWithPath: path, isDirectory: true),
                                          start: f, end: t, device: values["--device"],
                                          timezone: values["--timezone"] ?? "UTC", restingHR: rest,
                                          maxHR: maximum, engineRevision: revision))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("loop-replay: \(error)\n".utf8))
    exit(1)
}
