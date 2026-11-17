import SwiftUI
import MapKit

/// Carte du tracé GPS. Ne rend rien sans tracé réel (moins de deux points valides) : aucune carte
/// décorative ni position approximative.
struct WorkoutRouteMap: View {
    let route: WorkoutRoute?

    var body: some View {
        if let route, route.isDrawable {
            let coordinates = route.coordinates
                .filter { $0.latitude.isFinite && $0.longitude.isFinite }
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            Map(initialPosition: .automatic, interactionModes: []) {
                MapPolyline(coordinates: coordinates)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 220)
            .clipShape(.rect(cornerRadius: 26, style: .continuous))
            .accessibilityLabel(Text("today.carte.du.parcours", tableName: "Today"))
        }
    }
}
