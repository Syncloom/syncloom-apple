import SwiftUI

/// The Syncloom icon (two woven rings on a gradient squircle), drawn as vector so it is crisp at any size.
public struct BrandMark: View {
    let size: CGFloat
    public init(size: CGFloat = 64) { self.size = size }

    public var body: some View {
        Canvas { ctx, canvas in
            let k = canvas.width / 1024
            let bg = Path(roundedRect: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height), cornerRadius: 232 * k, style: .continuous)
            ctx.fill(bg, with: .linearGradient(Gradient(colors: [Color(red: 0.416, green: 0.361, blue: 1), Color(red: 0.07, green: 0.71, blue: 0.65)]),
                                               startPoint: CGPoint(x: 140 * k, y: 0), endPoint: CGPoint(x: 884 * k, y: 1024 * k)))
            let style = StrokeStyle(lineWidth: 76 * k, lineCap: .round)
            func ring(_ cx: CGFloat) -> Path { Path(ellipseIn: CGRect(x: (cx - 176) * k, y: (512 - 176) * k, width: 352 * k, height: 352 * k)) }
            ctx.stroke(ring(396), with: .color(.white), style: style)
            ctx.stroke(ring(628), with: .linearGradient(Gradient(colors: [Color(red: 0.79, green: 0.96, blue: 1), Color(red: 0.55, green: 0.91, blue: 0.95)]),
                                                        startPoint: CGPoint(x: 452 * k, y: 336 * k), endPoint: CGPoint(x: 804 * k, y: 688 * k)), style: style)
            // the white strand passes over the cyan ring at the top crossing
            var over = Path()
            for d in stride(from: -70.0, through: -22.0, by: 1.0) {
                let a = d * .pi / 180
                let p = CGPoint(x: (396 + 176 * cos(a)) * k, y: (512 + 176 * sin(a)) * k)
                if d == -70 { over.move(to: p) } else { over.addLine(to: p) }
            }
            ctx.stroke(over, with: .color(.white), style: StrokeStyle(lineWidth: 76 * k, lineCap: .butt))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Syncloom")
    }
}
