import SubtitolCore
import SwiftUI

/// The launch splash: the second the app is on screen while the language loads.
/// Grains of the orb's orange swirl in from the whole screen and gather into the orb,
/// which is already on its way from the middle to its place at the top; the name "duna" shows
/// faintly near the bottom. Everything then fades together and the reader's own orb is left exactly
/// where the gathered one was.
///
/// Cheap on purpose: a few hundred points in one `Canvas`, four fills a frame (one per
/// colour), no images, no shaders, nothing loaded. It removes itself when done.
struct LaunchSplash: View {
    /// Whether the screen under the splash shows the orb (the grains then land on it).
    let landsOnOrb: Bool
    /// Polled each frame once the orb has landed: the splash stays a moment longer while
    /// the language is still loading, never past `longestHold`.
    let isReady: () -> Bool
    let onFinished: () -> Void

    @AppStorage("phone.theme") private var theme: PhoneTheme = .automatic
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var clock = SplashClock()
    @State private var greetingShown = false
    @State private var fading = false

    /// Grains fly for `gather`; the splash then waits for the language up to
    /// `longestHold` more and fades over `fade`.
    private static let gather: Double = 1.2
    private static let longestHold: Double = 0.8
    private static let fade: Double = 0.4

    #if DEBUG
    /// `-splashTimeScale 4` plays it four times slower, to look at its frames.
    private static let timeScale: Double = {
        let value = UserDefaults.standard.double(forKey: "splashTimeScale")
        return value > 0 ? value : 1
    }()
    #else
    private static let timeScale: Double = 1
    #endif

    private var paper: ReadingTheme {
        let dark = switch theme {
        case .automatic: systemScheme == .dark
        case .light: false
        case .dark: true
        }
        return ReadingTheme.resolved(isDark: dark)
    }

    var body: some View {
        GeometryReader { proxy in
            let screen = CGSize(
                width: proxy.size.width,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            )
            let band = PhoneMetrics.orbHeight(in: proxy)
            let target = landsOnOrb
                ? CGPoint(x: screen.width / 2, y: proxy.safeAreaInsets.top + band / 2)
                : CGPoint(x: screen.width / 2, y: screen.height / 2)
            let radius = band * PhoneMetrics.orbRadiusRatio

            ZStack {
                paper.paper
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let elapsed = reduceMotion ? 10 : clock.advance(to: context.date) / Self.timeScale
                    ZStack {
                        Canvas { canvas, size in
                            draw(in: &canvas, size: size, elapsed: elapsed, target: target, radius: radius)
                        }
                        // The name as the website's masthead sets it (system font, semibold,
                        // tightened), low on the screen and faint: a signature, not a title.
                        Text(verbatim: "duna")
                            .font(.system(size: 24, weight: .semibold))
                            .tracking(-0.45)
                            .foregroundStyle(paper.ink)
                            .position(x: screen.width / 2, y: screen.height * 0.86)
                            .opacity(greetingShown ? 0.3 : 0)
                            .offset(y: greetingShown || reduceMotion ? 0 : 10)
                    }
                }
            }
            .frame(width: screen.width, height: screen.height)
            .ignoresSafeArea()
        }
        // One layer while it fades: faded piece by piece, the page showed through the orb.
        .compositingGroup()
        .opacity(fading ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await run() }
    }

    /// Follows the drawing's clock, so a stutter at launch delays the steps with the grains.
    private func run() async {
        let scale = Self.timeScale
        let wall = Date()
        func elapsed() -> Double {
            (reduceMotion ? Date().timeIntervalSince(wall) : clock.elapsed) / scale
        }
        func wait(until time: Double) async {
            while elapsed() < time { try? await Task.sleep(for: .milliseconds(16)) }
        }
        // The name waits for the orb to take shape: before it, the grains are still a cloud.
        await wait(until: 0.7)
        withAnimation(.easeOut(duration: 0.4 * scale)) { greetingShown = true }
        await wait(until: Self.gather)
        let landed = elapsed()
        while !isReady(), elapsed() - landed < Self.longestHold {
            try? await Task.sleep(for: .milliseconds(16))
        }
        withAnimation(.easeInOut(duration: Self.fade * scale)) { fading = true }
        try? await Task.sleep(for: .seconds(Self.fade * scale))
        #if DEBUG
        print("SPLASH frames=\(clock.frames) longestGap=\(Int(clock.longestGap * 1000))ms wall=\(Int(Date().timeIntervalSince(wall) * 1000))ms")
        #endif
        onFinished()
    }

    // MARK: - Drawing

    private static let colors: [Color] = [
        Color(red: 1, green: 100 / 255, blue: 0),   // #FF6400
        Color(red: 1, green: 120 / 255, blue: 0),   // #FF7800
        Color(red: 1, green: 164 / 255, blue: 0),   // #FFA400
        Color(red: 1, green: 194 / 255, blue: 0),   // #FFC200
    ]

    private func draw(in canvas: inout GraphicsContext, size: CGSize, elapsed t: Double,
                      target: CGPoint, radius: CGFloat) {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let centre = Self.orbCentre(in: size, target: target, elapsed: t)
        let reach = max(size.width, size.height) * 0.55

        // The body the grains fill: a soft disc that thickens as they arrive, so the
        // gathered orb has a surface to hand over to the real one.
        let body = Self.smoothstep(0.45, Self.gather, t)
        if body > 0 {
            let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            canvas.opacity = body
            canvas.fill(
                Path(ellipseIn: disc),
                // Like the orb at rest: amber above, the deep orange pooling underneath.
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Self.colors[2], location: 0),
                        .init(color: Self.colors[2], location: 0.45),
                        .init(color: Self.colors[0], location: 1),
                    ]),
                    startPoint: CGPoint(x: centre.x, y: centre.y - radius),
                    endPoint: CGPoint(x: centre.x, y: centre.y + radius)
                )
            )
        }

        var paths = [Path](repeating: Path(), count: Self.colors.count)
        for grain in Self.grains {
            // Each grain has its own arrival: the orb fills up rather than snapping shut.
            let q = Self.clamp((t - grain.delay) / (grain.arrival - grain.delay))
            let arrive = 1 - pow(1 - q, 3)
            let left = 1 - arrive
            // Swirl: the way still to go turns about the orb, faster far out.
            let home = CGPoint(x: centre.x + grain.home.x * radius, y: centre.y + grain.home.y * radius)
            let from = CGPoint(x: middle.x + grain.from.x * reach, y: middle.y + grain.from.y * reach)
            var dx = (from.x - home.x) * left
            var dy = (from.y - home.y) * left
            let angle = grain.spin * left * left
            (dx, dy) = (dx * cos(angle) - dy * sin(angle), dx * sin(angle) + dy * cos(angle))
            // Turbulence dies down as the grain settles; a faint shimmer stays.
            let wobble = 34 * left * left + 0.6
            let x = home.x + dx + wobble * sin(t * grain.rate + grain.phase)
            let y = home.y + dy + wobble * cos(t * grain.rate * 1.3 + grain.phase * 1.7)
            // A grain that has landed melts into the orb: none is left over its surface.
            let melt = 1 - Self.smoothstep(grain.arrival - 0.05, grain.arrival + 0.12, t)
            guard melt > 0 else { continue }
            let s = grain.size * (1.15 - 0.35 * arrive) * melt
            paths[grain.color].addEllipse(in: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s))
        }
        canvas.opacity = Self.smoothstep(0, 0.18, t)
        for (index, path) in paths.enumerated() {
            canvas.fill(path, with: .color(Self.colors[index]))
        }
    }

    /// Time as the frames saw it: a frame late by more than two frames' worth counts as
    /// two, so a busy launch slows the grains down instead of skipping their start. A
    /// reference, advanced while drawing, so it never invalidates the view.
    final class SplashClock {
        private var last: Date?
        private(set) var elapsed: Double = 0
        #if DEBUG
        var frames = 0
        var longestGap: Double = 0
        #endif

        func advance(to date: Date) -> Double {
            if let last {
                elapsed += min(max(0, date.timeIntervalSince(last)), 2 / 60)
                #if DEBUG
                frames += 1
                longestGap = max(longestGap, date.timeIntervalSince(last))
                #endif
            }
            last = date
            return elapsed
        }
    }

    private struct Grain {
        /// Where it starts, in units of the screen's longer side from the middle.
        var from: CGPoint
        /// Where it lands, in units of the orb's radius from its centre.
        var home: CGPoint
        var delay: Double
        /// When it reaches its place, in seconds from the start.
        var arrival: Double
        var spin: Double
        var rate: Double
        var phase: Double
        var size: CGFloat
        var color: Int
    }

    /// The same grains every launch: a fixed seed, made once.
    private static let grains: [Grain] = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<700).map { _ in
            let outward = 0.3 + 0.7 * sqrt(next())
            let bearing = next() * 2 * .pi
            let inward = sqrt(next()) * 0.97
            let landing = next() * 2 * .pi
            // Amber grains land high, deep orange ones low, like the orb's own colours.
            let height = sin(landing) * inward
            let warmth = max(0, min(3, Int((0.5 - height * 0.5) * 3.4 + next() * 1.1)))
            return Grain(
                from: CGPoint(x: cos(bearing) * outward, y: sin(bearing) * outward),
                home: CGPoint(x: cos(landing) * inward, y: sin(landing) * inward),
                delay: next() * 0.1,
                arrival: 0.55 + next() * (gather - 0.6),
                spin: (next() < 0.5 ? -1 : 1) * (1.4 + next() * 2.2),
                rate: 5 + next() * 9,
                phase: next() * 2 * .pi,
                size: 1.8 + CGFloat(next()) * 2.4,
                color: warmth
            )
        }
    }()

    /// The orb leaves the middle almost at once and eases into its place.
    private static func orbCentre(in size: CGSize, target: CGPoint, elapsed t: Double) -> CGPoint {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let travel = smoothstep(0.12, gather + 0.05, t)
        return CGPoint(
            x: middle.x + (target.x - middle.x) * travel,
            y: middle.y + (target.y - middle.y) * travel
        )
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let u = clamp((x - a) / (b - a))
        return u * u * (3 - 2 * u)
    }
}
