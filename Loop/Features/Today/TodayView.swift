import SwiftUI
import LoopStrapEngine

/// Today — read the day in one glance.
///
/// Three coloured hero rings (the kept `RingView`) sit above a contextual widget stack that
/// surfaces only what matters right now, ordered by `TodayContext`. Everything around the rings is
/// monochrome glass; the rings are the page's single locus of colour.
struct TodayView: View {
    @ObservedObject var repository: LoopDataRepository
    @EnvironmentObject private var connection: DeviceConnectionViewModel
    @EnvironmentObject private var coordinator: SyncCoordinator
    @ObservedObject private var prefs = UserPreferences.shared
    @EnvironmentObject private var router: AppRouter
    @State private var selectedDay: String?
    @State private var healthState: TodayHealthState = .loading
    @State private var healthNeedsAuthorization = false
    @State private var healthRevision = 0
    @State private var isAuthorizing = false
    @State private var healthSettingsSignature = TodayView.healthSettingsSignature()

    private let strainTarget: Double = 15.5

    var body: some View {
        NavigationStack(path: $router.todayPath) {
            ScrollView {
                VStack(spacing: 16) {
                    TodayHeader(
                        name: displayName,
                        dayTitle: headerDayTitle,
                        isSyncing: isBraceletSyncing,
                        isComputing: repository.isRefreshing,
                        computeProgress: computeFraction,
                        lastComputedAt: repository.cache.updatedAt,
                        computeError: repository.lastError
                    )

                    TodayRingsHero(rings: TodayRingModel.trio(from: todayMetric, strainTarget: strainTarget))

                    TodayWidgetStack(
                        widgets: context.widgets,
                        metric: todayMetric,
                        strainTarget: strainTarget,
                        stress: stressForSelectedDay,
                        samples: repository.cache.hrSamples,
                        day: todayMetric?.date ?? selectedDay,
                        sleepSessions: repository.cache.sleepSessions,
                        workoutSessions: repository.cache.workoutSessions,
                        onRejectWorkout: { repository.rejectWorkout($0) },
                        batteryPercent: normalizedBattery,
                        isCharging: connection.state.isCharging == true
                    )

                    if healthState != .hidden {
                        HealthDayWidget(state: healthState, needsAuthorization: healthNeedsAuthorization && !isAuthorizing, onAuthorize: {
                            guard !isAuthorizing else { return }
                            isAuthorizing = true
                            Task {
                                await HealthKitImporter.shared.sync(requestAccess: true)
                                await HealthSampleImporter().importAll(requestAccess: true)
                                isAuthorizing = false
                                healthRevision += 1
                            }
                        }, onRetry: { healthRevision += 1 })
                    }

                    TrainingAdviceWidget(insights: trainingInsights, isLoading: repository.isRefreshing,
                                         day: todayMetric?.date)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .refreshable { await repository.refresh() }
            .appBackground()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    DateNavigator(metrics: dailyMetrics, selectedDay: $selectedDay)
                }
            }
            .navigationDestination(for: MetricType.self) { type in
                if todayMetric != nil {
                    switch type {
                    case .sleep:
                        SleepDetailView(metrics: dailyMetrics, sessions: repository.cache.sleepSessions, selectedDay: $selectedDay)
                    case .recovery:
                        RecoveryDetailView(metrics: dailyMetrics, selectedDay: $selectedDay)
                    case .strain:
                        StrainDetailView(metrics: dailyMetrics, selectedDay: $selectedDay, repository: repository)
                    }
                }
            }
            .navigationDestination(for: TodayRoute.self) { route in
                switch route {
                case .stress:
                    if let stress = stressForSelectedDay { StressDetailView(snapshot: stress) }
                case .heartRate:
                    HeartRateDetailView(samples: repository.cache.hrSamples, metrics: dailyMetrics,
                                        loadSamples: repository.heartRateSamples)
                case .alarm:
                    AlarmView()
                case .trainingAdvice:
                    TrainingAdviceDetailView(insights: trainingInsights, isLoading: repository.isRefreshing)
                case .workout(let id):
                    WorkoutDetailView(sessionID: id, repository: repository)
                }
            }
            .onChange(of: dailyMetrics.map(\.date)) {
                guard !dailyMetrics.isEmpty else { selectedDay = nil; return }
                if let selectedDay, dailyMetrics.contains(where: { $0.date == selectedDay }) { return }
                selectedDay = dailyMetrics.last?.date
            }
            .task(id: healthLoadKey) { await loadHealthReport() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("loop.healthInputsChanged"))) { _ in
                healthRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("loop.healthEngineChanged"))) { _ in
                healthRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("loop.healthProducerPriorityChanged"))) { _ in
                healthRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                // Ne recharge le rapport santé que si les réglages santé (priorités) ont réellement changé.
                let signature = Self.healthSettingsSignature()
                guard signature != healthSettingsSignature else { return }
                healthSettingsSignature = signature
                healthRevision += 1
            }
        }
    }

    // MARK: - Context

    private static func healthSettingsSignature() -> String {
        let defaults = UserDefaults.standard
        return [HealthReconciliationSettings.storageKey, HealthReconciliationSettings.producerStorageKey]
            .map { key -> String in
                guard let value = defaults.object(forKey: key),
                      JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                else { return "" }
                return String(decoding: data, as: UTF8.self)
            }
            .joined(separator: "|")
    }

    private var healthDay: String {
        todayMetric?.date ?? selectedDay ?? Self.dayParser.string(from: Date())
    }

    private var healthLoadKey: String {
        "\(healthDay)|\(healthRevision)|\(repository.cache.updatedAt?.timeIntervalSince1970 ?? 0)|\(repository.localMetricsEngine == nil)"
    }

    @MainActor
    private func loadHealthReport() async {
        let day = healthDay
        guard repository.localMetricsEngine != nil else { healthState = .loading; return }
        let needsPermission = await TodayHealthAccess.needsPermission()
        guard !Task.isCancelled else { return }
        guard needsPermission != nil else { healthNeedsAuthorization = false; healthState = .hidden; return }
        healthNeedsAuthorization = needsPermission == true
        guard let report = await repository.healthDayReport(for: day) else {
            if !Task.isCancelled { healthState = .failed }
            return
        }
        guard !Task.isCancelled else { return }
        healthState = .loaded(report)
    }

    private var context: TodayContext {
        TodayContext(
            hasMetric: todayMetric != nil,
            isExpress: todayMetric?.isExpress == true,
            hasSleep: todayMetric.map { $0.totalSleepMin != nil || $0.sleepScore != nil } ?? false,
            hasTimeline: hasTimelineEntries,
            stressNotable: stressNotable,
            hasCardio: !repository.cache.hrSamples.isEmpty,
            batteryPercent: normalizedBattery,
            isCharging: connection.state.isCharging == true,
            alarmEnabled: prefs.alarmEnabled,
            strainGoalReached: StrainTargetState.make(metric: todayMetric, strainTarget: strainTarget).shouldShow
        )
    }

    // MARK: - Derived data

    private var dailyMetrics: [DailySnapshot] {
        repository.cache.daily.sorted { $0.date < $1.date }
    }

    private var todayMetric: DailySnapshot? {
        guard !dailyMetrics.isEmpty else { return nil }
        let day = selectedDay ?? dailyMetrics.last?.date
        return dailyMetrics.first { $0.date == day } ?? dailyMetrics.last
    }

    private var stressForSelectedDay: StressSnapshot? {
        guard let stress = repository.cache.stress else { return nil }
        let day = todayMetric?.date ?? selectedDay
        guard day == nil || stress.date == day else { return nil }
        return stress
    }

    /// La carte « Journée » n'apparaît que s'il y a au moins une entrée affichable (fragments exclus).
    private var hasTimelineEntries: Bool {
        guard let day = todayMetric?.date ?? selectedDay else { return false }
        return !DayTimelineBuilder.build(day: day, sleep: repository.cache.sleepSessions,
                                         workouts: repository.cache.workoutSessions).entries.isEmpty
    }

    private var stressNotable: Bool {
        guard let s = stressForSelectedDay else { return false }
        return s.summary.avgScore != nil || s.summary.highMinutes > 0
    }

    /// `nil` when viewing today (the header greets); otherwise the browsed day's date in French.
    private var headerDayTitle: String? {
        guard let day = todayMetric?.date ?? selectedDay, let date = Self.dayParser.date(from: day) else { return nil }
        if Calendar.current.isDateInToday(date) { return nil }
        return Self.dayTitleFormatter.string(from: date).capitalized
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent  // jour local, même politique que le moteur
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    private var displayName: String {
        let trimmed = prefs.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Théo" : trimmed
    }

    private var isBraceletSyncing: Bool {
        if case .syncing = coordinator.status { return true }
        return false
    }

    private var normalizedBattery: Double? {
        guard let pct = connection.state.batteryPct, pct.isFinite else { return nil }
        return pct <= 1 ? pct * 100 : pct
    }

    /// Flatten the repository's (stage, completed, total) progress into a 0…1 fraction for the header.
    /// Single adapter point for the training insights. `LoopDataRepository.trainingReport` is added by
    /// lot-c1-rpe-detail; once it exists, derive from it here (e.g. its insights array). Until then:
    /// no data, the widget shows its "absent" state rather than inventing a reading.
    private var trainingInsights: [TrainingInsight] { repository.trainingReport?.insights ?? [] }

    private var computeFraction: Double? {
        guard let p = repository.computeProgress, p.total > 0 else { return nil }
        return Double(p.completed) / Double(p.total)
    }
}

enum TodayRoute: Hashable {
    case stress
    case heartRate
    case alarm
    case trainingAdvice
    /// Détail d'une séance ouvert depuis la timeline « Journée » (accueil ou Strain).
    case workout(String)
}

#Preview {
    TodayView(repository: LoopDataRepository())
        .environmentObject(DeviceConnectionViewModel())
        .environmentObject(SmartAlarmController())
        .environmentObject(SyncCoordinator())
        .environmentObject(AppRouter())
}
