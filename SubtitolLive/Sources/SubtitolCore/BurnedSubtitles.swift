@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// How the captions look in the picture: a few words at a time, pure white, in the face
/// and size the reader chose, with a soft shadow and a dark outline each on or off, where
/// the reader put them (low and centred unless moved). A caption appears and leaves at
/// once, on the frame its first word starts: captions that fade lag behind the voice.
public struct CaptionStyle: Equatable, Sendable {
    /// Type size at 100 %, as a share of the picture's shorter side.
    public static let standardRatio: CGFloat = 0.065
    /// The sizes the − and + buttons step through, as a share of the standard size.
    public static let scaleRange: ClosedRange<CGFloat> = 0.5...2.0
    public static let scaleStep: CGFloat = 0.1

    public var font: CaptionFont
    /// Type size as a share of the standard size (1 = 100 %).
    public var scale: CGFloat {
        didSet { scale = Self.steppedScale(scale) }
    }
    /// Words on screen at a time, 1–3, or 0 for a whole line at a time (as broadcast
    /// subtitles are).
    public var wordsPerCue: Int
    public var shadow: Bool
    public var stroke: Bool
    /// Where the middle of the text sits, as a share of the picture's width and height;
    /// `nil` keeps it centred low in the frame.
    public var position: CGPoint?

    /// 0 stands for a whole line.
    public static let wordChoices = [1, 2, 3, 0]

    public init(
        font: CaptionFont = .default,
        scale: CGFloat = 1,
        wordsPerCue: Int = 2,
        shadow: Bool = true,
        stroke: Bool = false,
        position: CGPoint? = nil
    ) {
        self.font = font
        self.scale = Self.steppedScale(scale)
        self.wordsPerCue = min(3, max(0, wordsPerCue))
        self.shadow = shadow
        self.stroke = stroke
        self.position = position.map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
    }

    /// Type size as a share of the picture's shorter side.
    public var ratio: CGFloat { Self.standardRatio * scale }

    /// On the steps of the − and + buttons, inside their range.
    static func steppedScale(_ scale: CGFloat) -> CGFloat {
        let stepped = (scale / scaleStep).rounded() * scaleStep
        return min(scaleRange.upperBound, max(scaleRange.lowerBound, stepped))
    }

    /// Width the text may take, and distance of its lowest row from the bottom edge:
    /// higher in portrait pictures, whose bottom is covered by the apps they are shared to.
    static func layout(for size: CGSize) -> (maxWidth: CGFloat, bottomMargin: CGFloat) {
        let portrait = size.height > size.width * 1.1
        return (size.width * (portrait ? 0.84 : 0.78), size.height * (portrait ? 0.17 : 0.08))
    }

    // MARK: - Remembered choices

    private enum Key {
        static let words = "captions.wordsPerCue"
        static let scale = "captions.scale"
        /// The first version's four sizes.
        static let namedSize = "captions.size"
        static let font = "captions.typeface"
        static let shadow = "captions.shadow"
        static let stroke = "captions.stroke"
        static let positionX = "captions.positionX"
        static let positionY = "captions.positionY"
    }

    /// The reader's last choices, for the next video and for its `.srt`.
    public static var saved: CaptionStyle {
        let defaults = UserDefaults.standard
        let position: CGPoint? = defaults.object(forKey: Key.positionX) == nil ? nil
            : CGPoint(x: defaults.double(forKey: Key.positionX), y: defaults.double(forKey: Key.positionY))
        return CaptionStyle(
            font: defaults.string(forKey: Key.font).flatMap(CaptionFont.init(rawValue:)) ?? .default,
            scale: (defaults.object(forKey: Key.scale) as? Double).map { CGFloat($0) } ?? Self.namedScale(defaults.string(forKey: Key.namedSize)),
            wordsPerCue: defaults.object(forKey: Key.words) as? Int ?? 2,
            shadow: defaults.object(forKey: Key.shadow) as? Bool ?? true,
            stroke: defaults.object(forKey: Key.stroke) as? Bool ?? false,
            position: position
        )
    }

    private static func namedScale(_ name: String?) -> CGFloat {
        switch name {
        case "small": 0.8
        case "large": 1.3
        case "extraLarge": 1.7
        default: 1
        }
    }

    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(font.rawValue, forKey: Key.font)
        defaults.set(Double(scale), forKey: Key.scale)
        defaults.removeObject(forKey: Key.namedSize)
        defaults.set(wordsPerCue, forKey: Key.words)
        defaults.set(shadow, forKey: Key.shadow)
        defaults.set(stroke, forKey: Key.stroke)
        if let position {
            defaults.set(Double(position.x), forKey: Key.positionX)
            defaults.set(Double(position.y), forKey: Key.positionY)
        } else {
            defaults.removeObject(forKey: Key.positionX)
            defaults.removeObject(forKey: Key.positionY)
        }
    }
}

/// Draws the captions of a set of cues for a picture of any size, from any thread.
/// Every caption drawn is kept for a while, so playing costs one drawing per caption,
/// not one per frame.
public final class CaptionRenderer: @unchecked Sendable {
    /// One caption to lay over the picture: `frame` is in the picture's points with the
    /// origin at the top left.
    public struct Layer {
        public let image: CGImage
        public let frame: CGRect
    }

    public let cues: [SubtitleDocument.Cue]
    public let style: CaptionStyle
    private let starts: [TimeInterval]
    private let store: ImageStore

    private struct Key: Hashable {
        let cue: Int
        let width: Int
        let height: Int
    }

    /// The drawn captions, shared by renderers that differ only in where they put them.
    private final class ImageStore: @unchecked Sendable {
        let lock = NSLock()
        var images: [Key: CGImage] = [:]
        var order: [Key] = []
        static let limit = 64
    }

    public init(cues: [SubtitleDocument.Cue], style: CaptionStyle) {
        self.cues = cues
        self.style = style
        starts = cues.map(\.start)
        store = ImageStore()
    }

    private init(cues: [SubtitleDocument.Cue], style: CaptionStyle, starts: [TimeInterval], store: ImageStore) {
        self.cues = cues
        self.style = style
        self.starts = starts
        self.store = store
    }

    /// The same captions somewhere else: nothing is drawn again, so dragging them is free.
    public func placed(at position: CGPoint?) -> CaptionRenderer {
        var moved = style
        moved.position = position
        return CaptionRenderer(cues: cues, style: moved, starts: starts, store: store)
    }

    /// The document's captions, `style.wordsPerCue` words at a time.
    public convenience init(document: SubtitleDocument, style: CaptionStyle) {
        self.init(cues: document.cues(wordsPerCue: style.wordsPerCue), style: style)
    }

    /// The caption on screen at `time` in a picture of `size`, if any.
    public func layers(at time: TimeInterval, pictureSize size: CGSize) -> [Layer] {
        guard size.width > 0, size.height > 0, let index = cueIndex(at: time),
              let drawn = image(cue: index, pictureSize: size) else { return [] }
        return [Layer(image: drawn.image, frame: drawn.frame)]
    }

    /// The caption at `time`, or else the nearest one: something to place while the
    /// reader moves the captions during a pause.
    public func nearestLayers(at time: TimeInterval, pictureSize size: CGSize) -> [Layer] {
        guard size.width > 0, size.height > 0, let index = nearestCueIndex(at: time) else { return [] }
        return image(cue: index, pictureSize: size).map { [Layer(image: $0.image, frame: $0.frame)] } ?? []
    }

    /// Where the text of the caption at `time` (or the nearest one) sits, without the room
    /// its shadow takes: what a drag holds and keeps inside the picture.
    public func textFrame(at time: TimeInterval, pictureSize size: CGSize) -> CGRect? {
        guard let layer = nearestLayers(at: time, pictureSize: size).first else { return nil }
        let padding = Self.padding(fontSize: Self.fontSize(style: style, pictureSize: size))
        return layer.frame.insetBy(dx: padding, dy: padding)
    }

    private func nearestCueIndex(at time: TimeInterval) -> Int? {
        if let shown = cueIndex(at: time) { return shown }
        guard !cues.isEmpty else { return nil }
        let next = starts.firstIndex { $0 > time } ?? cues.count - 1
        let previous = max(0, next - 1)
        return abs(cues[next].start - time) < abs(time - cues[previous].end) ? next : previous
    }

    private static func fontSize(style: CaptionStyle, pictureSize size: CGSize) -> CGFloat {
        (min(size.width, size.height) * style.ratio).rounded()
    }

    private static func padding(fontSize: CGFloat) -> CGFloat { (fontSize * 0.7).rounded(.up) }

    /// The cue shown at `time`: the last one started, until its end.
    public func cueIndex(at time: TimeInterval) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, time < cues[low - 1].end else { return nil }
        return low - 1
    }

    /// The captions at `time` as one image the size of the picture, for the video
    /// composition (Core Image's origin is at the bottom left).
    public func overlay(at time: TimeInterval, pictureSize size: CGSize) -> CIImage? {
        layers(at: time, pictureSize: size).first.map { layer in
            CIImage(cgImage: layer.image).transformed(by: CGAffineTransform(
                translationX: layer.frame.minX,
                y: size.height - layer.frame.maxY
            ))
        }
    }

    private func image(cue index: Int, pictureSize size: CGSize) -> (image: CGImage, frame: CGRect)? {
        let key = Key(cue: index, width: Int(size.width), height: Int(size.height))
        let fontSize = Self.fontSize(style: style, pictureSize: size)
        let layout = CaptionStyle.layout(for: size)
        let padding = Self.padding(fontSize: fontSize)

        let image: CGImage
        store.lock.lock()
        let cached = store.images[key]
        store.lock.unlock()
        if let cached {
            image = cached
        } else {
            let text = cues[index].words.map(\.text).joined(separator: " ")
            guard let drawn = Self.draw(text, fontSize: fontSize, maxWidth: layout.maxWidth, padding: padding, style: style) else { return nil }
            image = drawn
            store.lock.lock()
            store.images[key] = drawn
            store.order.append(key)
            if store.order.count > ImageStore.limit {
                store.images[store.order.removeFirst()] = nil
            }
            store.lock.unlock()
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var frame = CGRect(
            x: ((size.width - width) / 2).rounded(),
            y: (size.height - layout.bottomMargin - height + padding).rounded(),
            width: width,
            height: height
        )
        if let position = style.position {
            // The text itself (the image less its shadow room) stays inside the picture.
            let textWidth = width - padding * 2
            let textHeight = height - padding * 2
            let x = min(max(position.x * size.width, textWidth / 2), size.width - textWidth / 2)
            let y = min(max(position.y * size.height, textHeight / 2), size.height - textHeight / 2)
            frame.origin = CGPoint(x: (x - width / 2).rounded(), y: (y - height / 2).rounded())
        }
        return (image, frame)
    }

    /// The text centred in rows no wider than `maxWidth`, pure white over a soft shadow.
    static func draw(
        _ string: String,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        padding: CGFloat,
        style: CaptionStyle
    ) -> CGImage? {
        let font = style.font.font(ofSize: fontSize)
        var alignment = CTTextAlignment.center
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraph = withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &lineBreak) { breakBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: breakBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        guard !string.isEmpty else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
        ]
        let text = NSAttributedString(string: string, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil
        )
        let textWidth = min(maxWidth, ceil(fitted.width))
        let textHeight = ceil(fitted.height)
        let width = Int(textWidth + padding * 2)
        let height = Int(textHeight + padding * 2)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setShouldSmoothFonts(false)
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: textWidth, height: textHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        // The outline is the same text stroked twice as wide as it shows, under the fill,
        // so it grows outwards and the letters keep their shape.
        let outline: CTFrame? = style.stroke ? {
            var stroked = attributes
            stroked[kCTStrokeWidthAttributeName as NSAttributedString.Key] = 18
            stroked[kCTStrokeColorAttributeName as NSAttributedString.Key] = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.92)
            let strokedText = NSAttributedString(string: string, attributes: stroked)
            return CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(strokedText as CFAttributedString), CFRange(location: 0, length: 0), path, nil)
        }() : nil
        context.setLineJoin(.round)
        let base = outline ?? frame
        if style.shadow {
            // A wide soft shadow lifts the text off bright pictures; a tight one draws
            // its edge on busy ones.
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.36, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.62))
            CTFrameDraw(base, context)
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.02), blur: fontSize * 0.08, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
            CTFrameDraw(base, context)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        if let outline { CTFrameDraw(outline, context) }
        // The letters themselves stay pure white.
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}

/// Writes a copy of a video with its captions burnt into the picture: the same size,
/// frame rate and codec family (HEVC stays HEVC), at the highest quality the system
/// encoder offers, with the sound and the file's metadata carried over.
public enum CaptionedVideoExport {
    public enum ExportError: LocalizedError {
        case noPicture
        case unsupported

        public var errorDescription: String? {
            switch self {
            case .noPicture: localized("Aquest fitxer no té imatge.")
            case .unsupported: localized("No es pot fer una còpia d'aquest vídeo.")
            }
        }
    }

    /// `progress` receives 0...1 from the export's own thread.
    public static func export(
        source: URL,
        renderer: CaptionRenderer,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noPicture }
        let formats = try await track.load(.formatDescriptions)
        let isHEVC = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }

        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let picture = request.sourceImage
            let time = request.compositionTime.seconds
            if let captions = renderer.overlay(at: time, pictureSize: picture.extent.size) {
                let placed = captions.transformed(by: CGAffineTransform(translationX: picture.extent.minX, y: picture.extent.minY))
                request.finish(with: placed.composited(over: picture).cropped(to: picture.extent), context: nil)
            } else {
                request.finish(with: picture, context: nil)
            }
        }

        let preset = isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ExportError.unsupported }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        let fileType: AVFileType = destination.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        try? FileManager.default.removeItem(at: destination)

        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let exporting) = state { progress(exporting.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: destination, as: fileType)
        progress(1)
    }
}
