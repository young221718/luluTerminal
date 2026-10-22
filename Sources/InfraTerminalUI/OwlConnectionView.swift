import SwiftUI

/// Native rendering of the shared eyes-owl.svg; no metric state enters this view.
struct OwlConnectionView: View {
    let active: Bool

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 100, y: size.height / 100)
            let ink = GraphicsContext.Shading.foreground
            var rim = Path()
            rim.move(to: CGPoint(x: 39, y: 70))
            rim.addCurve(to: CGPoint(x: 26, y: 75), control1: CGPoint(x: 35, y: 74), control2: CGPoint(x: 31, y: 75))
            rim.addCurve(to: CGPoint(x: 3, y: 50), control1: CGPoint(x: 12, y: 75), control2: CGPoint(x: 3, y: 64))
            rim.addCurve(to: CGPoint(x: 27, y: 24), control1: CGPoint(x: 3, y: 35), control2: CGPoint(x: 13, y: 24))
            rim.addCurve(to: CGPoint(x: 50, y: 38), control1: CGPoint(x: 37, y: 24), control2: CGPoint(x: 45, y: 30))
            rim.addCurve(to: CGPoint(x: 73, y: 24), control1: CGPoint(x: 55, y: 30), control2: CGPoint(x: 63, y: 24))
            rim.addCurve(to: CGPoint(x: 97, y: 50), control1: CGPoint(x: 87, y: 24), control2: CGPoint(x: 97, y: 35))
            rim.addCurve(to: CGPoint(x: 74, y: 75), control1: CGPoint(x: 97, y: 64), control2: CGPoint(x: 88, y: 75))
            rim.addCurve(to: CGPoint(x: 61, y: 70), control1: CGPoint(x: 69, y: 75), control2: CGPoint(x: 65, y: 74))
            context.stroke(rim, with: ink, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
            var pupils = Path()
            for x in [28.0, 72.0] {
                pupils.addEllipse(in: CGRect(x: x - 10, y: active ? 36 : 47.7, width: 20, height: active ? 26 : 2.6))
            }
            context.fill(pupils, with: ink)
            if active {
                context.blendMode = .destinationOut
                for x in [26.0, 70.0] {
                    context.fill(Path(ellipseIn: CGRect(x: x - 2.7, y: 39.3, width: 5.4, height: 5.4)), with: .color(.white))
                }
                context.blendMode = .normal
            }
            var beak = Path()
            beak.move(to: CGPoint(x: 50, y: 62))
            beak.addCurve(to: CGPoint(x: 57, y: 69), control1: CGPoint(x: 54, y: 62), control2: CGPoint(x: 58, y: 65))
            beak.addCurve(to: CGPoint(x: 51.3, y: 80.5), control1: CGPoint(x: 55, y: 74), control2: CGPoint(x: 53, y: 78))
            beak.addQuadCurve(to: CGPoint(x: 48.7, y: 80.5), control: CGPoint(x: 50, y: 82.5))
            beak.addCurve(to: CGPoint(x: 43, y: 69), control1: CGPoint(x: 47, y: 78), control2: CGPoint(x: 45, y: 74))
            beak.addCurve(to: CGPoint(x: 50, y: 62), control1: CGPoint(x: 42, y: 65), control2: CGPoint(x: 46, y: 62))
            beak.closeSubpath()
            context.fill(beak, with: ink)
        }.accessibilityHidden(true)
    }
}
