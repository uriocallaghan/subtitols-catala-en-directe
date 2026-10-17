import SubtitolCore
import SwiftUI

// The languages' own marks, shared by the Mac and the iPhone: the figure that leads
// every language row, the Beta tag, and the app's Inter.

/// The mark that leads each row: a small geometric figure of overlapping translucent
/// shapes, one per language, in the project's oranges.
///
/// On this iPhone: in colour. To download: the same figure in faint ink. Downloading:
/// the colour rises through the grey figure from the bottom with a gentle wave, and a
/// finished download fills it to the top. Languages without a figure show their code.
struct LanguageCircle: View {
    enum Look: Equatable {
        case active
        case installed
        case available
        case downloading(Double)
    }

    static let orange = Color(red: 1, green: 0.392, blue: 0)

    let languageID: String
    let look: Look
    let palette: SettingsBarPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the figure is in colour.
    private var level: Double {
        switch look {
        case .active, .installed: 1
        case .downloading(let fraction): 0.08 + 0.92 * fraction
        case .available: 0
        }
    }

    private var isWaving: Bool {
        if case .downloading = look { return !reduceMotion }
        return false
    }

    var body: some View {
        ZStack {
            LanguageFigure(languageID: languageID, colourful: false, ink: palette.ink)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isWaving)) { context in
                let phase = isWaving ? context.date.timeIntervalSinceReferenceDate * 2.6 : 0
                LanguageFigure(languageID: languageID, colourful: true, ink: palette.ink)
                    .mask {
                        WaveShape(level: level, phase: phase, amplitude: isWaving ? 1.6 : 0)
                    }
            }
        }
        .scaleEffect(look == .active ? 1.08 : 1)
        // Slow enough to see the colour rise when a language is chosen.
        .animation(.spring(response: 0.9, dampingFraction: 0.88), value: look)
        .accessibilityHidden(true)
    }
}

/// One language's figure, drawn in a square: circles and petals laid over each other so
/// their overlaps deepen, like stained glass. `colourful` false draws it in faint ink.
struct LanguageFigure: View {
    let languageID: String
    let colourful: Bool
    let ink: Color

    private static let tones: [Color] = [
        Color(red: 1, green: 0.392, blue: 0),   // #FF6400
        Color(red: 1, green: 0.55, blue: 0),    // #FF8C00
        Color(red: 1, green: 0.65, blue: 0),    // #FFA600
        Color(red: 1, green: 0.761, blue: 0),   // #FFC200
    ]

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let u = side / 2
            let shapes = Self.shapes(for: languageID, centre: c, unit: u)
            guard !shapes.isEmpty else { return }
            for shape in shapes {
                let fill: Color = colourful
                    ? Self.tones[shape.tone % Self.tones.count].opacity(0.78)
                    : ink.opacity(0.13)
                context.fill(shape.path, with: .color(fill))
            }
        }
        .overlay {
            if Self.shapes(for: languageID, centre: .zero, unit: 1).isEmpty {
                Text(languageID.uppercased())
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(colourful ? Self.tones[0] : ink.opacity(0.5))
            }
        }
    }

    private struct Piece {
        let path: Path
        let tone: Int
    }

    private static func circle(_ centre: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func point(_ c: CGPoint, _ r: CGFloat, _ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }

    /// A pointed petal from the centre outwards, `length` long, at `degrees`.
    private static func petal(_ c: CGPoint, length: CGFloat, width: CGFloat, _ degrees: Double) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.5, y: -width))
        p.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.5, y: width))
        p.closeSubpath()
        return p.applying(CGAffineTransform(translationX: c.x, y: c.y).rotated(by: degrees * .pi / 180))
    }

    private static func shapes(for id: String, centre c: CGPoint, unit u: CGFloat) -> [Piece] {
        switch id {
        case "ca":
            // Four upright bars leaning on each other, a quiet nod to the four stripes.
            return (0..<4).map { i in
                let x = c.x + (CGFloat(i) - 1.5) * u * 0.36
                let rect = CGRect(x: x - u * 0.2, y: c.y - u * 0.74, width: u * 0.4, height: u * 1.48)
                let bar = Path(roundedRect: rect, cornerRadius: u * 0.2)
                    .applying(CGAffineTransform(translationX: -c.x, y: -c.y))
                    .applying(CGAffineTransform(a: 1, b: 0, c: -0.22, d: 1, tx: 0, ty: 0))
                    .applying(CGAffineTransform(translationX: c.x, y: c.y))
                return Piece(path: bar, tone: [0, 2, 1, 3][i])
            }
        case "es":
            // Three circles in a triangle.
            return [-90.0, 30, 150].enumerated().map { i, a in
                Piece(path: circle(point(c, u * 0.34, a), u * 0.54), tone: [1, 0, 3][i])
            }
        case "en":
            // A diamond of four small circles around a fifth.
            let ring = [-90.0, 0, 90, 180].enumerated().map { i, a in
                Piece(path: circle(point(c, u * 0.56, a), u * 0.32), tone: [3, 1, 0, 2][i])
            }
            return ring + [Piece(path: circle(c, u * 0.34), tone: 0)]
        case "gl":
            // A star of six pointed petals.
            return (0..<6).map { i in
                Piece(path: petal(c, length: u * 0.96, width: u * 0.5, Double(i) * 60 - 90), tone: i % 4)
            }
        case "eu":
            // Two rounded squares, one turned an eighth: an eight-pointed star.
            return [0.0, 45].enumerated().map { i, a in
                let side = u * 1.36
                let square = Path(roundedRect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side), cornerRadius: u * 0.1)
                    .applying(CGAffineTransform(rotationAngle: a * .pi / 180))
                    .applying(CGAffineTransform(translationX: c.x, y: c.y))
                return Piece(path: square, tone: [0, 3][i])
            }
        default:
            return []
        }
    }
}

/// The part of a shape under a liquid surface at `level` (0 empty, 1 full).
private struct WaveShape: Shape {
    var level: Double
    var phase: Double
    var amplitude: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, amplitude) }
        set {
            level = newValue.first
            amplitude = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let surface = rect.maxY - rect.height * level
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        let steps = 24
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let x = rect.minX + rect.width * fraction
            let y = surface + amplitude * sin(fraction * .pi * 2 + phase)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct BetaBadge: View {
    let text: String
    let palette: SettingsBarPalette
    var size: CGFloat = 11

    var body: some View {
        // Light grey, like the other tags: beta is information, not an alarm.
        Text(text)
            .font(.inter(size, relativeTo: .caption2))
            .foregroundStyle(palette.ink.opacity(0.62))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.well))
    }
}

extension Font {
    /// Inter Medium, the app's reading face, the only Inter the app carries.
    static func inter(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(AppVisualMetrics.readingFontName, size: size, relativeTo: style)
    }
}
