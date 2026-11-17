import SwiftUI

/// Strain du jour : un score héros, puis une grille de widgets classés par utilité, chacun masqué
/// quand sa donnée manque (spec design §7.1). Fond uni, cartes opaques, verre réservé à la toolbar.
struct StrainDetailView: View {
    let metrics: [DailySnapshot]
    @Binding var selectedDay: String?
    /// Fournit séances (saisie RPE) et analyse d'entraînement ; sans lui ces widgets sont masqués.
    var repository: LoopDataRepository? = nil

    private var sortedMetrics: [DailySnapshot] {
        metrics.sorted { $0.date < $1.date }
    }

    private var metric: DailySnapshot? {
        let day = selectedDay ?? sortedMetrics.last?.date
        return sortedMetrics.first { $0.date == day } ?? sortedMetrics.last
    }

    private var model: StrainCoachModel? {
        guard let metric else { return nil }
        return StrainCoachModel(metric: metric, history: sortedMetrics)
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, LoopMeasure.screenGutter)
                .padding(.top, 8)
                .padding(.bottom, 34)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .appBackground()
        // Contrôles de la page à la teinte de sa métrique (spec design §4.2).
        .tint(Metric.strain.tint)
        .navigationTitle("Strain")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                DateNavigator(metrics: sortedMetrics, selectedDay: $selectedDay)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            if let repository {
                StrainObservedDashboard(model: model, repository: repository)
            } else {
                StrainDashboard(model: model, repository: nil, hasWorkouts: false, hasInsights: false)
            }
        } else if repository?.isRefreshing == true {
            // Chargement : gabarit final masqué, pas de spinner.
            StrainHeroSection(model: .preview(strain: 12.0))
                .redacted(reason: .placeholder)
                .accessibilityLabel(Text("today.strain.en.cours.de.calcul", tableName: "Today"))
        } else {
            ContentUnavailableView {
                Label(TodayL.text("today.final.missing.strain"), systemImage: Metric.strain.symbol)
            } description: {
                Text("today.porte.le.bracelet.pour.mesurer.ta.charge.du.jour", tableName: "Today")
            }
            .padding(.top, 40)
        }
    }
}

// MARK: - Observing wrapper

/// Observes the repository so the workouts / insights widgets appear or hide as data lands.
private struct StrainObservedDashboard: View {
    let model: StrainCoachModel
    @ObservedObject var repository: LoopDataRepository

    var body: some View {
        StrainDashboard(
            model: model,
            repository: repository,
            hasWorkouts: !repository.workoutSessions(forDay: model.metric.date).isEmpty,
            hasInsights: TrainingInsightsCard.isAvailable(repository)
        )
    }
}

// MARK: - Dashboard

private struct StrainDashboard: View {
    let model: StrainCoachModel
    let repository: LoopDataRepository?
    let hasWorkouts: Bool
    let hasInsights: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LoopMeasure.sectionSpacing) {
            StrainHeroSection(model: model)
                .padding(.top, 8)
            DynamicWidgetGrid(widgets: widgets)
        }
    }

    /// Fixed order by usefulness (spec §7.0-7.1). Only the advice moves with the data: it already
    /// carries the overload alert, so it stays first.
    private var widgets: [DynamicWidget] {
        [
            DynamicWidget(id: "advice", priority: 10, isAvailable: !model.isCalibrating) {
                AdviceBlock(overline: model.adviceOverline,
                            title: model.adviceTitle,
                            message: model.adviceMessage,
                            contradiction: model.adviceContradiction)
            },
            DynamicWidget(id: "dayLoad", priority: 20, isAvailable: model.hasDayLoad) {
                StrainDayLoadWidget(model: model)
            },
            // Toujours présent avec le dépôt : porte l'ajout d'une séance saisie à la main.
            DynamicWidget(id: "workouts", priority: 30, isAvailable: repository != nil) {
                if let repository {
                    StrainWorkoutsSection(repository: repository, day: model.metric.date)
                }
            },
            DynamicWidget(id: "day", priority: 35, isAvailable: repository != nil) {
                if let repository {
                    DayTimelineCard(day: model.metric.date,
                                    sleep: repository.cache.sleepSessions,
                                    workouts: repository.cache.workoutSessions,
                                    isLoading: repository.isRefreshing,
                                    onReject: { repository.rejectWorkout($0) })
                }
            },
            DynamicWidget(id: "acwr", priority: 40, span: .half, isAvailable: model.acwrRatio != nil) {
                StrainAcuteChronicTile(model: model)
            },
            DynamicWidget(id: "week", priority: 41, span: .half, isAvailable: model.weeklyTrendDelta != nil) {
                StrainWeeklyDeltaTile(model: model)
            },
            DynamicWidget(id: "zones", priority: 50, isAvailable: model.zones != nil && model.activeZoneMinutes > 0) {
                StrainZonesWidget(model: model)
            },
            DynamicWidget(id: "trend", priority: 60, isAvailable: model.hasWeekTrend) {
                StrainWeekTrendWidget(model: model)
            },
            DynamicWidget(id: "insights", priority: 70, isAvailable: hasInsights && repository != nil) {
                if let repository {
                    TrainingInsightsCard(repository: repository, day: model.metric.date)
                }
            },
            DynamicWidget(id: "why", priority: 80, isAvailable: true) {
                StrainWhyDisclosure(model: model)
            }
        ]
    }
}

// MARK: - Hero

private struct StrainHeroSection: View {
    let model: StrainCoachModel

    var body: some View {
        let s = model.heroState
        ScoreHero(
            metric: .strain,
            overline: TodayL.text("today.remaining.strain.today"),
            value: model.heroValueText,
            unit: model.isCalibrating ? nil : "/21",
            state: s.state,
            stateText: s.text,
            context: model.heroContext,
            partialNote: model.heroPartialNote,
            accessibilityValue: model.isCalibrating ? TodayL.text("today.remaining.unavailable") : TodayL.format("today.remaining.strain.score", model.heroValueText)
        )
    }
}

#Preview("Complet") {
    StrainDetailPreview(strain: 14.2)
}

#Preview("Dépassé") {
    StrainDetailPreview(strain: 18.4)
}

#Preview("Calibrage") {
    StrainDetailPreview(strain: nil)
}

private struct StrainDetailPreview: View {
    let strain: Double?
    @State private var selectedDay: String?

    var body: some View {
        NavigationStack {
            StrainDetailView(metrics: StrainCoachModel.preview(strain: strain).history, selectedDay: $selectedDay)
        }
    }
}
