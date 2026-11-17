import SwiftUI

/// « Journée » de l'accueil : même timeline que la page Strain (`DayTimelineCard`, fusion et
/// filtrage par `DayTimelineBuilder`). Masquée par `TodayContext` quand le jour n'a aucun événement.
/// Le rejet d'une séance reste disponible par le menu contextuel.
struct TimelineWidget: View {
    let day: String?
    let sleep: [SleepSession]
    let workouts: [WorkoutSession]
    var onReject: ((WorkoutSession) -> Void)? = nil

    var body: some View {
        DayTimelineCard(day: day, sleep: sleep, workouts: workouts, onReject: onReject)
    }
}
