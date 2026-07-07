import SwiftUI

struct RingView: View {
    let percent: Double
    let color: Color
    var lineWidth: CGFloat = 3
    var filled: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            if filled {
                Circle()
                    .trim(from: 0, to: min(max(percent / 100, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}
