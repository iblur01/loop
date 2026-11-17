import SwiftUI

struct RingView: View {
    let color: Color
    let current: Double
    let maxValue: Double
    let targetMin: Double
    let targetMax: Double
    let lineWidth: CGFloat

    init(
        color: Color,
        current: Double,
        maxValue: Double,
        targetMin: Double,
        targetMax: Double,
        lineWidth: CGFloat = 10
    ) {
        self.color = color
        self.current = current
        self.maxValue = maxValue
        self.targetMin = targetMin
        self.targetMax = targetMax
        self.lineWidth = lineWidth
    }

    private var currentFraction: Double {
        normalized(current)
    }

    private var targetStartFraction: Double {
        min(normalized(targetMin), normalized(targetMax))
    }

    private var targetEndFraction: Double {
        max(normalized(targetMin), normalized(targetMax))
    }

    private var targetMidFraction: Double {
        clamp((targetStartFraction + targetEndFraction) / 2)
    }

    private var visibleTargetStartFraction: Double {
        max(targetStartFraction, currentFraction)
    }

    private var visibleTargetEndFraction: Double {
        targetEndFraction
    }

    private var hasVisibleTarget: Bool {
        visibleTargetEndFraction > visibleTargetStartFraction
    }

    private var shouldShowTargetMidIndicator: Bool {
        hasVisibleTarget &&
        targetMidFraction >= visibleTargetStartFraction &&
        targetMidFraction <= visibleTargetEndFraction
    }

    private var subtleStroke: StrokeStyle {
        StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .butt,
            lineJoin: .round
        )
    }

    var body: some View {
        ZStack {
            // Track translucide
            RingArc()
                .stroke(.primary.opacity(0.08), style: subtleStroke)

            // Zone cible visible, deja decoupee pour ne jamais passer sous l'arc courant.
            if hasVisibleTarget {
                RingArc(from: visibleTargetStartFraction, to: visibleTargetEndFraction)
                    .stroke(
                        .primary.opacity(0.20),
                        style: subtleStroke
                    )
            }

            // Indicateur milieu zone cible, seulement s'il reste dans la portion visible.
            if shouldShowTargetMidIndicator {
                RingArc(
                    from: max(0, targetMidFraction - 0.002),
                    to: min(1, targetMidFraction + 0.002)
                )
                .stroke(.secondary.opacity(0.55), style: subtleStroke)
            }

            // Progression principale
            RingArc(from: 0, to: currentFraction)
                .stroke(
                    LinearGradient(
                        colors: [
                            color,
                            color.opacity(0.76)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: subtleStroke
                )
                .shadow(color: color.opacity(0.25), radius: 8, x: 0, y: 0)
                .animation(.smooth(duration: 0.8), value: currentFraction)

        }
        .padding(lineWidth / 2)
    }

    private func normalized(_ value: Double) -> Double {
        guard maxValue > 0, value.isFinite else { return 0 }
        return clamp(value / maxValue)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private struct RingArc: Shape {
    var from: Double = 0
    var to: Double = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let startAngle = Angle.degrees(-90 + (360 * from))
        let endAngle = Angle.degrees(-90 + (360 * to))

        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )

        return path
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(white: 0.08).ignoresSafeArea()

        RingView(
            color: Color(hue: 0.55, saturation: 0.95, brightness: 1),
            current: 15.2,
            maxValue: 21,
            targetMin: 13,
            targetMax: 17
        )
        .frame(width: 96, height: 96)
    }
}
