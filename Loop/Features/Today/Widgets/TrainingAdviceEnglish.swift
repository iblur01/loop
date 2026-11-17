import Foundation

/// English templates use the same fact placeholders as the calculation engine's French table.
enum TrainingAdviceEnglish {
    static let strings: [String: String] = {
        var s: [String: String] = [:]
        func add(_ key: String, _ short: String, _ detail: String) {
            s["training.\(key).short"] = short
            s["training.\(key).detail"] = detail
        }
        add("load_ratio.calibration", "Load calibration: {data_days} of {required_days} required days of data.", "The recent-to-usual load ratio requires {required_days} days of load data in the last {chronic_days} days. There are currently {data_days}; no conclusion is drawn.")
        add("load_ratio.norecent", "No recent load data (last reading {days_since_last} days ago).", "The recent-to-usual load ratio is not calculated without data from the last {acute_days} days.")
        add("load_ratio.unavailable", "Load ratio unavailable: usual load is nearly zero.", "Smoothed usual load ({chronic}) is too close to zero for a reliable ratio.")
        let ratioDetail = "Cardio load smoothed over {acute_days} days ({acute}) is {ratio} times the load smoothed over {chronic_days} days ({chronic}), based on {data_days} days of data."
        for (key, text) in [("high", "Recent load is much higher than usual"), ("rising", "Recent load is slightly higher than usual"), ("stable", "Recent load is close to usual"), ("low", "Recent load is lower than usual")] {
            add("load_ratio.\(key)", "\(text) (ratio {ratio}).", ratioDetail)
        }
        s["training.note.low_confidence_inputs"] = "More than half of the daily loads used have low confidence ({low_confidence_pct} %), limiting this reading."
        add("monotony.insufficient", "Load variety: {known_days} of {window_days} days known; {required_days} required.", "Monotony (mean divided by standard deviation of daily load) requires {required_days} known days in the last {window_days} days. Missing days are not counted as zero.")
        add("monotony.undefined", "Load variety cannot be calculated: load is identical on every known day.", "Daily load does not vary across {known_days} known days among the last {window_days}; standard deviation is zero, so monotony is undefined.")
        for (key, short, comparison) in [("high", "Daily load varied little this week", "above"), ("normal", "Daily load varied this week", "below")] {
            add("monotony.\(key)", "\(short) (monotony {monotony}).", "Across {known_days} known days among the last {window_days}, monotony is {monotony}, \(comparison) the {threshold} reference. This describes load regularity, not risk.")
        }
        add("regularity.insufficient", "Regularity: history is too short ({tracked_days} of {required_days} days).", "At least {required_days} days of history are needed to assess workout regularity; {tracked_days} are available.")
        add("regularity.none", "No workouts recorded in the recent period.", "No workouts in the last {tracked_days} tracked days; the last was {days_since_last} days ago.")
        add("regularity.single", "Only one active day in {tracked_days} tracked days.", "{active_days} workout day in {tracked_days} tracked days; the last workout was {days_since_last} days ago. Spacing cannot be calculated from one active day.")
        add("regularity.ok", "{active_days} active days in {tracked_days} tracked days.", "{active_days} workout days in {tracked_days} tracked days. The longest gap between active days is {max_gap_days} days; the last workout was {days_since_last} days ago.")
        add("sleep_trend.insufficient", "Sleep trend: insufficient data.", "{recent_n} recent nights (at least {required_recent} required) and {reference_n} reference nights (at least {required_reference} required).")
        for (direction, comparison) in [("down", "below"), ("up", "above"), ("stable", "close to")] {
            add("sleep_trend.\(direction)", "Recent sleep duration is \(comparison) your baseline ({sleep_recent_h} h versus {sleep_reference_h} h).", "Median for the last {recent_days} days: {sleep_recent_h} h, versus {sleep_reference_h} h over the preceding {reference_days} days, a difference of {sleep_delta_h} h ({delta_mad} MAD). Based on {recent_n} recent and {reference_n} reference nights.")
        }
        s["training.note.sleep_low_coverage"] = "Sleep coverage is partial (about {sleep_coverage_pct} %), reducing confidence."
        add("conflict.sleep_low_recovery_high", "Conflicting signals: short sleep but high recovery.", "Last night's sleep ({sleep_last_h} h) is {sleep_delta_h} h below your baseline ({sleep_reference_h} h, {delta_mad} MAD), while your recovery score is {recovery_score}. Neither indicator alone is enough to draw a conclusion.")
        add("conflict.sleep_ok_recovery_low", "Conflicting signals: usual sleep but low recovery.", "Last night's sleep ({sleep_last_h} h) is close to your baseline ({sleep_reference_h} h), while your recovery score is {recovery_score}. Neither indicator alone is enough to draw a conclusion.")
        add("conflict.feeling_low_recovery_high", "Conflicting signals: low reported feeling but high recovery.", "Your reported feeling ({feeling} out of {feeling_max}) is low while your recovery score is {recovery_score}.")
        add("conflict.feeling_high_recovery_low", "Conflicting signals: good reported feeling but low recovery.", "Your reported feeling ({feeling} out of {feeling_max}) is good while your recovery score is {recovery_score}.")
        s["training.note.experimental_recovery"] = "The recovery score is experimental."
        for (key, sport) in [("run", "running"), ("swim", "swimming"), ("strength", "strength training")] {
            add("volume.\(key).insufficient", "\(sport.capitalized) volume: history is too short ({tracked_days} of {required_days} days).", "At least {required_days} days of history are needed to compare recent volume with your usual level; {tracked_days} are available.")
            let detail = "\(sport.capitalized) sessions over {recent_days} days: {recent_sessions}, versus an average of {prior_sessions_mean} per {recent_days}-day period over the preceding {prior_days} days."
            for (direction, text) in [("up", "higher"), ("down", "lower"), ("stable", "stable")] {
                add("volume.\(key).\(direction)", "\(sport.capitalized) volume is \(text) compared with usual.", detail)
            }
        }
        s["training.note.volume_minutes"] = "Total duration: {recent_minutes} min over {recent_days} days, versus an average of {prior_minutes_mean} min per preceding period."
        s["training.note.volume_srpe"] = "Perceived effort load (sRPE multiplied by duration): {srpe_load_recent} arbitrary units over {recent_days} days."
        s["training.note.no_hr_strength"] = "Strength training is not assessed using heart rate: only the number, duration, and supplied perceived effort (sRPE) of workouts are used."
        s["training.note.no_hr_swim"] = "Heart rate is not used to estimate swimming intensity: only volume is compared."
        let changeDetail = "A cumulative sum (CUSUM) reaches {statistic} against a threshold of {threshold}, using {recent_points} points from the last {recent_days} days compared with {reference_points} reference points. Estimated onset {onset_days_ago} days ago. This statistical detection needs confirmation over time."
        for (key, metric) in [("load", "daily cardio load"), ("sleep", "sleep duration"), ("recovery", "recovery score")] {
            for (direction, comparison) in [("up", "higher"), ("down", "lower")] {
                add("change.\(key).\(direction)", "Change detected: \(metric) is \(comparison) than your baseline.", changeDetail)
            }
        }
        let linkDetail = "Absolute Spearman rank correlation of {rho_abs} over {n} pairs of days, with an approximate interval of {ci_abs_low} to {ci_abs_high}."
        for (key, label) in [("load_sleep", "Daily load and next night's sleep duration"), ("load_recovery", "Daily load and next day's recovery"), ("sleep_recovery", "Sleep duration and recovery"), ("efficiency_recovery", "Sleep efficiency and recovery")] {
            add("link.\(key).pos", "\(label): tendency to move in the same direction.", linkDetail)
            add("link.\(key).neg", "\(label): tendency to move in opposite directions.", linkDetail)
            add("link.\(key).insufficient", "\(label): insufficient data.", "{n} pairs of days available; at least {required_n} are required for an exploratory correlation.")
        }
        s["training.note.exploratory_link"] = "Exploratory correlation, not causation."
        let chrome: [String: String] = [
            "training.widget.title": "Training advice", "training.widget.loading": "Analyzing your training.",
            "training.widget.absent.title": "No advice yet", "training.widget.absent.body": "No reading is available because training data is missing. No conclusion is drawn.",
            "training.widget.calibration.badge": "Calibration", "training.widget.insufficient.badge": "Insufficient data",
            "training.widget.partial.badge": "Partial data", "training.widget.contradictory.badge": "Conflicting signals",
            "training.widget.other_conflict": "Another conflicting signal", "training.widget.cta": "See details",
            "training.confidence.label": "Confidence", "training.confidence.low": "low", "training.confidence.medium": "medium",
            "training.confidence.high": "high", "training.confidence.none": "Confidence unavailable", "training.experimental": "Experimental",
            "training.detail.title": "Training advice", "training.detail.contributors": "Factors considered",
            "training.detail.notes": "Notes", "training.detail.others": "Other readings",
            "training.detail.none": "No readings are currently available.", "training.contributor.unknown": "Other factor"
        ]
        s.merge(chrome) { _, english in english }
        let contributors: [String: String] = [
            "active_days": "Workout days", "acute_ewma_7d": "Smoothed recent load", "calibration": "Calibration duration",
            "chronic_ewma_28d": "Smoothed usual load", "cusum": "Cumulative sum (CUSUM)",
            "daily_load_constant": "Constant daily load", "daily_load_coverage": "Days with known load",
            "daily_load_dispersion": "Load dispersion", "daily_load_mean": "Average daily load", "history_length": "History length",
            "paired_days": "Day pairs", "personal_reference": "Personal baseline", "rank_correlation": "Rank correlation",
            "recent_load_missing": "Missing recent load", "recovery_score": "Recovery score (experimental)",
            "reported_feeling": "Reported feeling", "session_count": "Number of workouts", "session_spacing": "Workout spacing",
            "sleep_duration": "Sleep duration", "sleep_duration_median": "Median sleep duration",
            "sleep_duration_vs_personal_reference": "Sleep versus your baseline", "low_confidence_inputs": "Low-confidence daily loads"
        ]
        for (key, value) in contributors { s["training.contributor.\(key)"] = value }
        return s
    }()
}
