import SwiftUI

/// The three hero rings — Sleep · Recovery · Strain — read at a glance, each tapping through to its
/// detail. One sober glass surface holding the page's only colour. No badges, no chevrons clutter.
struct TodayRingsHero: View {
    let rings: [TodayRingModel]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(rings) { ring in
                NavigationLink(value: ring.type) {
                    TodayRing(model: ring)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 10)
        .loopGlass(cornerRadius: 30)
    }
}

#Preview {
    TodayRingsHero(rings: TodayRingModel.trio(from: nil, strainTarget: 15.5))
        .padding()
}
