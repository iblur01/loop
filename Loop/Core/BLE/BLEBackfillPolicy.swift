import Foundation

/// What prompted a sync attempt. Mirrors WHOOP (15-min periodic floor + event-triggered "process now"
/// syncs + the strap's own prompt events + manual), adapted to iOS.
enum BackfillTrigger {
    case periodic    // the repeating timer while connected+bonded
    case connect     // a (re)connect / bond confirmation
    case foreground  // the app became active (scenePhase .active)
    case manual      // the user tapped "Sync now"
    case strap       // an incoming strap EVENT packet (WHOOP's HighFreqSyncPrompt analog)
    case continuation // follow-up pass right after an idle-timeout that still made progress
    case charging    // the phone was just plugged in (or an external-power background task fired)
}

/// Where the phone is in its power/usage cycle. Drives how eagerly we offload: aggressively when the
/// phone is on a charger (typically overnight), sparingly in the background on battery.
enum PowerContext: Equatable {
    case foreground            // app on screen: user is looking at the data
    case charging              // background, on a charger
    case backgroundOnBattery   // background, unplugged
    case backgroundLowPower    // background, unplugged, Low Power Mode

    static func current(appActive: Bool, charging: Bool, lowPowerMode: Bool) -> PowerContext {
        if appActive { return .foreground }
        if charging { return .charging }
        return lowPowerMode ? .backgroundLowPower : .backgroundOnBattery
    }

    /// Minimum gap between periodic/strap-event syncs.
    var periodicFloorSeconds: TimeInterval {
        switch self {
        case .foreground, .charging: return 900        // 15 min, matches WHOOP
        case .backgroundOnBattery:   return 3600       // 1 h: a few radio wake-ups per day
        case .backgroundLowPower:    return 7200       // 2 h
        }
    }

    /// Max chained follow-up passes after progress-making timeouts. Deep catch-up only on a charger.
    var maxContinuations: Int {
        switch self {
        case .charging:                             return 30
        case .foreground:                           return 4
        case .backgroundOnBattery, .backgroundLowPower: return 1
        }
    }

    var isBatterySaving: Bool { self == .backgroundOnBattery || self == .backgroundLowPower }
}

/// Pure rate-limiter for historical-offload kicks. No BLE/store deps. Floors match WHOOP
/// (observed: ~15-min periodic + expedited event syncs).
enum BackfillPolicy {
    static let periodicFloorSeconds: TimeInterval = 900   // 15 min
    static let eventFloorSeconds: TimeInterval = 90       // absorbs reconnect-flaps / event bursts

    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?,
                          context: PowerContext = .foreground) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        switch trigger {
        case .manual, .continuation:         return true
        case .connect, .foreground, .charging:
            return elapsed >= eventFloorSeconds
        case .strap:
            // Strap EVENTs are frequent; on battery they must not wake the radio more than periodic does.
            return elapsed >= (context.isBatterySaving ? context.periodicFloorSeconds : eventFloorSeconds)
        case .periodic:
            return elapsed >= max(periodicFloorSeconds, context.periodicFloorSeconds)
        }
    }
}
