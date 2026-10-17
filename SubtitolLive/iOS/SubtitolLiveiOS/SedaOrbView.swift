import MetalKit
import SubtitolCore
import SwiftUI

/// The voice orb of the "Versió final" design: Seda, rendered live and driven by the
/// microphone through `OrbMotionDynamics`.
///
/// It reads the level on demand each frame, never through published state, so the
/// transcript is not re-rendered at frame rate for decoration.
struct SedaOrbView: UIViewRepresentable {
    /// Pulls the loudest level since the last frame.
    let voiceLevel: () -> Float
    let isListening: Bool
    /// The page behind the orb; the orb's own background matches it exactly.
    let background: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> SedaRenderer { SedaRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        context.coordinator.configure(view)
        update(context.coordinator, view: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        update(context.coordinator, view: view)
    }

    private func update(_ renderer: SedaRenderer, view: MTKView) {
        renderer.voiceLevel = voiceLevel
        renderer.isListening = isListening
        renderer.reduceMotion = reduceMotion
        renderer.background = SIMD4<Float>(background)
        view.clearColor = MTLClearColor(background)
        // Idle is calm: a lower frame rate spares the battery while nothing is heard.
        view.preferredFramesPerSecond = isListening && !reduceMotion ? 60 : 30
    }
}

final class SedaRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var dynamics = OrbMotionDynamics(theta: 0.5)
    private var lastTimestamp: CFTimeInterval?

    var voiceLevel: () -> Float = { 0 }
    var isListening = false
    var reduceMotion = false
    var background = SIMD4<Float>(0.98, 0.98, 0.98, 1)

    func configure(_ view: MTKView) {
        guard let device, pipeline == nil else { return }
        queue = device.makeCommandQueue()
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "sedaVertex"),
              let fragment = library.makeFunction(name: "sedaFragment") else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Grain studies for comparing settings (Debug only): `-orbGrainMode 1…7` blends a
    /// grey layer in an editor's blend mode at `-orbGrainMix`, `-orbGrainAmount` sets the
    /// dither of mode 0, and `-orbFreeze YES` holds one frame so captures match.
    private struct DebugGrain {
        var mode: Float = 0
        var mix: Float = 0.25
        var amount: Float?
        var freeze = false
    }

    private static let debug: DebugGrain = {
        var value = DebugGrain()
        #if DEBUG
        let defaults = UserDefaults.standard
        value.mode = defaults.float(forKey: "orbGrainMode")
        if defaults.object(forKey: "orbGrainMix") != nil { value.mix = defaults.float(forKey: "orbGrainMix") }
        if defaults.object(forKey: "orbGrainAmount") != nil { value.amount = defaults.float(forKey: "orbGrainAmount") }
        value.freeze = defaults.bool(forKey: "orbFreeze")
        #endif
        return value
    }()

    /// The grain is redrawn 24 times a second, like film. Under Reduce Motion it
    /// changes only a few times a second, a shimmer rather than a fizz.
    private func grainSeed(at time: CFTimeInterval) -> Float {
        let rate = reduceMotion ? 4.0 : 24.0
        return Float((time * rate).rounded(.down).truncatingRemainder(dividingBy: 97))
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let delta = lastTimestamp.map { now - $0 } ?? 0
        lastTimestamp = now
        // Under Reduce Motion the silk keeps its slow drift but the voice no longer
        // shakes it: it answers only by brightening a little.
        var frame = dynamics.advance(
            deltaTime: Self.debug.freeze ? 0 : delta,
            voiceLevel: reduceMotion ? 0 : voiceLevel(),
            listening: isListening
        )
        if reduceMotion { frame.level = 0 }

        guard let pipeline,
              let queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = SedaUniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            theta: Float(frame.theta),
            level: Float(frame.level),
            motion: 0.4,
            react: 1.18,
            size: Float(frame.size),
            square: 0,
            edge: 0,
            deform: Float(frame.deform),
            deformDetail: Float(frame.deformDetail),
            fold: 0.82,
            foldAngle: 12.6,
            crest: Float(frame.crest),
            crestWidth: 3,
            turbulence: Float(frame.turbulence),
            turbulenceScale: 2.892,
            balance: Float(frame.balance),
            contrast: 0.92,
            // Finer and lighter than the study's 1.32 at one point: on a phone held at
            // reading distance the coarser grain read as a screen over the orb. A stronger
            // grain (1.4) was tried and turned down on 2026-09-27.
            grain: Self.debug.amount ?? 0.9,
            grainSize: 0.62,
            scale: Float(view.contentScaleFactor),
            flow: Float(frame.flow),
            churn: Float(frame.churn),
            grainSeed: Self.debug.freeze ? 7 : grainSeed(at: now),
            grainMode: Self.debug.mode,
            grainMix: Self.debug.mix,
            color1: SIMD4(1, 100 / 255, 0, 1),
            color2: SIMD4(1, 120 / 255, 0, 1),
            color3: SIMD4(1, 164 / 255, 0, 1),
            color4: SIMD4(1, 194 / 255, 0, 1),
            background: background
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SedaUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Mirrors `SedaUniforms` in SedaOrb.metal field for field; the float4 colours keep
/// both layouts aligned without padding arithmetic.
struct SedaUniforms {
    var resolution: SIMD2<Float>
    var theta: Float
    var level: Float
    var motion: Float
    var react: Float
    var size: Float
    var square: Float
    var edge: Float
    var deform: Float
    var deformDetail: Float
    var fold: Float
    var foldAngle: Float
    var crest: Float
    var crestWidth: Float
    var turbulence: Float
    var turbulenceScale: Float
    var balance: Float
    var contrast: Float
    var grain: Float
    var grainSize: Float
    var scale: Float
    var flow: Float
    var churn: Float
    var grainSeed: Float
    var grainMode: Float
    var grainMix: Float
    var color1: SIMD4<Float>
    var color2: SIMD4<Float>
    var color3: SIMD4<Float>
    var color4: SIMD4<Float>
    var background: SIMD4<Float>
}

extension SIMD4 where Scalar == Float {
    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(Float(red), Float(green), Float(blue), Float(alpha))
    }
}

extension MTLClearColor {
    init(_ color: Color) {
        let c = SIMD4<Float>(color)
        self.init(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1)
    }
}
