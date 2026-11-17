import Foundation

// strapcapture — phase 1: capture raw WHOOP 4.0 offload frames to an fsync'd JSONL file.
// No decoding, no database. See StrapSession for the durability/ACK invariant.

setvbuf(stdout, nil, _IOLBF, 0)

func usage() -> Never {
    print("""
    usage: strapcapture [--out PATH] [--no-ack] [--idle-timeout SECONDS]
      --out PATH             capture file (append, never overwritten)
                             default: ~/LoopCaptures/capture-<yyyyMMdd-HHmmss>.jsonl
      --no-ack               observe only: never ACK HISTORY_END (strap will not trim)
      --idle-timeout SECS    end the session after SECS without notifications (default 60)
    """)
    exit(64)
}

func defaultOutPath() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/LoopCaptures/capture-\(f.string(from: Date())).jsonl"
}

var options = StrapSession.Options(outPath: defaultOutPath(), ack: true, idleTimeout: 60)
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--out":
        guard let v = args.popFirst() else { usage() }
        options.outPath = (v as NSString).expandingTildeInPath
    case "--no-ack":
        options.ack = false
    case "--idle-timeout":
        guard let v = args.popFirst(), let s = Double(v), s > 0 else { usage() }
        options.idleTimeout = s
    case "-h", "--help":
        usage()
    default:
        print("unknown argument: \(a)")
        usage()
    }
}

let capture: CaptureFile
do {
    capture = try CaptureFile(path: options.outPath)
} catch {
    log("FATAL: \(error.localizedDescription)")
    exit(4)
}

let session = StrapSession(options: options, capture: capture)

// Clean stop on Ctrl-C / SIGTERM: close the file, log the end, cancel the connection.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { session.end(reason: sig == SIGINT ? "interrupted" : "terminated", code: 130) }
    src.resume()
    signalSources.append(src)
}

session.start()
dispatchMain()
