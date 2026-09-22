import AppKit
import MetalKit
import OSLog
import QuartzCore
import SubtitolCore
import SwiftUI

/// A full-resolution Retina noise field whose only voice-driven dimension is speed.
///
/// The `MTKView` owns its clock, motion state, and render cadence. SwiftUI can rebuild
/// the transcript as often as it needs without restarting or invalidating the field.
struct ProceduralShaderView: NSViewRepresentable {
    let voiceLevel: () -> Float
    let discardPendingVoicePeak: () -> Void
    let isRecording: Bool

    func makeNSView(context: Context) -> MetalNoiseView {
        MetalNoiseView(
            voiceLevel: voiceLevel,
            discardPendingVoicePeak: discardPendingVoicePeak,
            isRecording: isRecording
        )
    }

    func updateNSView(_ view: MetalNoiseView, context: Context) {
        view.update(isRecording: isRecording)
    }
}

final class MetalNoiseView: MTKView {
    private static let idleFramesPerSecond = 12
    private static let recordingFramesPerSecond = 30
    private static let fallbackColor = MTLClearColor(red: 1, green: 0.42, blue: 0, alpha: 1)

    private var renderer: MetalNoiseRenderer?
    private var wasVisible = false
    private var occlusionObserver: NSObjectProtocol?

    override var isOpaque: Bool { true }

    init(
        voiceLevel: @escaping () -> Float,
        discardPendingVoicePeak: @escaping () -> Void,
        isRecording: Bool
    ) {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())

        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .invalid
        sampleCount = 1
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        clearColor = Self.fallbackColor
        layer?.backgroundColor = NSColor(
            srgbRed: 1,
            green: 0.42,
            blue: 0,
            alpha: 1
        ).cgColor

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
            metalLayer.allowsNextDrawableTimeout = true
            metalLayer.presentsWithTransaction = false
        }

        do {
            renderer = try MetalNoiseRenderer(
                view: self,
                voiceLevel: voiceLevel,
                discardPendingVoicePeak: discardPendingVoicePeak
            )
            delegate = renderer
        } catch {
            ShaderLog.renderer.error(
                "No s'ha pogut iniciar el shader Metal: \(error.localizedDescription, privacy: .public)"
            )
        }

        update(isRecording: isRecording)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    func update(isRecording: Bool) {
        preferredFramesPerSecond = isRecording
            ? Self.recordingFramesPerSecond
            : Self.idleFramesPerSecond
        updateDrawingState()
        syncDrawableSize()
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateDrawingState()
            }
        }
        updateDrawingState()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let backingBounds = convertToBacking(bounds)
        let size = CGSize(
            width: max(1, backingBounds.width.rounded()),
            height: max(1, backingBounds.height.rounded())
        )
        guard drawableSize != size else { return }
        drawableSize = size
    }

    private func updateDrawingState() {
        let shouldDraw = renderer != nil
            && window?.occlusionState.contains(.visible) == true
        if shouldDraw && !wasVisible {
            renderer?.resetClock()
        }
        wasVisible = shouldDraw
        isPaused = !shouldDraw
    }
}

private final class MetalNoiseRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var viewportSize: SIMD2<Float>
        var phase: Float
        var padding: Float = 0
    }

    let voiceLevel: () -> Float
    let discardPendingVoicePeak: () -> Void

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let uniformBuffers: [MTLBuffer]
    private let availableFrames = DispatchSemaphore(value: 2)
    private var uniformIndex = 0
    private var motion = ShaderMotionDynamics()
    private var previousTime: CFTimeInterval?

    init(
        view: MTKView,
        voiceLevel: @escaping () -> Float,
        discardPendingVoicePeak: @escaping () -> Void
    ) throws {
        guard let device = view.device else { throw RendererError.noDevice }
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }

        guard let sourceURL = ShaderResources.bundle?.url(
            forResource: "ProceduralNoise",
            withExtension: "metal"
        ) else {
            throw RendererError.missingShaderSource
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "noiseVertex"),
              let fragment = library.makeFunction(name: "noiseFragment") else {
            throw RendererError.missingFunctions
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Subtitol noise field"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        self.commandQueue = commandQueue
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        uniformBuffers = try (0..<2).map { index in
            guard let buffer = device.makeBuffer(
                length: MemoryLayout<Uniforms>.stride,
                options: .storageModeShared
            ) else {
                throw RendererError.noUniformBuffer
            }
            buffer.label = "Shader uniforms \(index)"
            return buffer
        }
        self.voiceLevel = voiceLevel
        self.discardPendingVoicePeak = discardPendingVoicePeak
        super.init()
    }

    func resetClock() {
        previousTime = nil
        discardPendingVoicePeak()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard availableFrames.wait(timeout: .now()) == .success else { return }

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            availableFrames.signal()
            return
        }

        let now = CACurrentMediaTime()
        if let previousTime {
            motion.advance(deltaTime: now - previousTime, voiceLevel: voiceLevel())
        }
        previousTime = now

        let buffer = uniformBuffers[uniformIndex]
        uniformIndex = (uniformIndex + 1) % uniformBuffers.count
        var uniforms = Uniforms(
            viewportSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            phase: Float(motion.phase)
        )
        withUnsafePointer(to: &uniforms) { source in
            buffer.contents().copyMemory(
                from: UnsafeRawPointer(source),
                byteCount: MemoryLayout<Uniforms>.stride
            )
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [availableFrames] _ in
            availableFrames.signal()
        }
        commandBuffer.commit()
    }

    private enum RendererError: LocalizedError {
        case noDevice
        case noCommandQueue
        case missingShaderSource
        case missingFunctions
        case noUniformBuffer

        var errorDescription: String? {
            switch self {
            case .noDevice: "No hi ha cap dispositiu Metal disponible."
            case .noCommandQueue: "No s'ha pogut crear la cua Metal."
            case .missingShaderSource: "No s'ha trobat el recurs del shader Metal."
            case .missingFunctions: "La biblioteca Metal no conté les funcions esperades."
            case .noUniformBuffer: "No s'han pogut reservar els uniforms del shader."
            }
        }
    }
}

private enum ShaderLog {
    static let renderer = Logger(subsystem: "cat.subtitollive.mvp", category: "shader")
}

private enum ShaderResources {
    private static let bundleName = "SubtitolLive_SubtitolLive.bundle"

    static let bundle: Bundle? = {
        let installed = Bundle.main.resourceURL?.appendingPathComponent(bundleName)
        let development = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(bundleName)
        return [installed, development]
            .compactMap { $0 }
            .lazy
            .compactMap(Bundle.init(url:))
            .first
    }()
}
