@preconcurrency import AVFoundation
import SubtitolCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// The subtitle editor, shared by the Mac and the iPhone: the film on top (on the Mac, at
// the side), the lines below it like a song's lyrics. The line being said is bright and
// its words light up as they are spoken; the others rest in grey. Touching a line plays
// it and opens it for correcting, in place, in the same type. Everything moves on
// springs; under Reduce Motion it cross-fades.

struct SubtitleEditorView: View {
    @ObservedObject var model: SubtitleEditorModel
    let theme: ReadingTheme
    let palette: SettingsBarPalette
    let typeface: ReadingTypeface
    /// The iPhone's single column; the Mac lays the film beside the lines.
    var isCompact = false
    /// What the share glyph's panel does with the text and the `.srt`.
    let textActions: [ExportAction]
    @Binding var exportFormat: TranscriptExportFormat
    /// How the finished burnt-in copy leaves the app (the Mac's save and AirDrop).
    var videoActions: (URL) -> [ExportAction] = { _ in [] }
    /// Room left at the start of the header (the Mac's window buttons sit there).
    var leadingInset: CGFloat = 0
    let onClose: () -> Void

    static let motion = Animation.spring(response: 0.42, dampingFraction: 0.86)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    /// The export card: the video with its subtitles, or the subtitles and text alone.
    @State private var showsExport = false
    @AppStorage("editor.exportsVideo") private var exportsVideo = true
    /// The lines' type follows the reader's text size.
    @ScaledMetric(relativeTo: .title2) private var wideLyricSize: CGFloat = 27
    @ScaledMetric(relativeTo: .title2) private var compactLyricSize: CGFloat = 23
    /// The iPhone's caption style: the lines step aside and the film takes their room,
    /// with the choices docked under it. The Mac shows the choices under the film.
    @State private var isStyling = false
    /// The film as drawn, in points.
    @State private var shownPictureSize: CGSize = .zero
    /// While the captions are dragged: from the finger to the text's middle, in points,
    /// and half the text's size, as shares of the picture.
    @State private var grab: CGSize?
    @State private var grabbedHalf: CGSize = .zero
    /// The middles the caption is held to, and counters that tap the hand.
    @State private var snappedX = false
    @State private var snappedY = false
    @State private var snaps = 0
    @State private var grabs = 0
    @State private var exportSheetHeight: CGFloat = 420

    private var panelMotion: Animation { reduceMotion ? .easeInOut(duration: 0.22) : Self.motion }

    var body: some View {
        Group {
            if isCompact { compactLayout } else { wideLayout }
        }
        .background(theme.paper)
        .background { keyboardCommands }
        #if os(iOS)
        .sheet(isPresented: $showsExport, onDismiss: model.dismissVideoExport) { exportSheet }
        #endif
        .onChange(of: model.editingLineID) { _, editing in
            if editing != nil, showsExport { closePanels() }
        }
        .onChange(of: model.exportRequest) { _, _ in
            if !model.document.isEmpty { openExport(video: nil) }
        }
        #if DEBUG
        .task { await runDebugSteps() }
        #endif
    }

    #if DEBUG
    @MainActor private static var scriptedEditors: Set<UUID> = []

    /// Test runs: `-editorSteps "play@1;pause@4;edit 2@5;draft Bon dia@7;commit@9;undo@11;export@13;text@20;close@30"`,
    /// seconds from the editor opening.
    private func runDebugSteps() async {
        guard let script = UserDefaults.standard.string(forKey: "editorSteps") else { return }
        // SwiftUI may build the presented screen twice; the steps run once per editor, in
        // a copy that waits while another runs them and takes over if that one is dropped.
        while Self.scriptedEditors.contains(model.id) {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        Self.scriptedEditors.insert(model.id)
        let opened = Date()
        for step in script.split(separator: ";") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { continue }
            let wait = at - Date().timeIntervalSince(opened)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            // A screen built twice drops its first copy: the steps go on in the one shown.
            if Task.isCancelled {
                Self.scriptedEditors.remove(model.id)
                return
            }
            let command = parts[0].split(separator: " ", maxSplits: 1).map(String.init)
            let argument = command.count > 1 ? command[1] : ""
            switch command.first ?? "" {
            case "play", "pause": model.togglePlayback()
            case "seek": model.seek(to: Double(argument) ?? 0)
            case "edit":
                if let index = Int(argument), index < model.document.lines.count { model.edit(model.document.lines[index].id) }
            case "draft": model.draft = argument
            case "commit": model.commit()
            case "next": model.commitAndEditNext()
            case "undo": model.undo()
            case "export":
                openExport(video: true)
                model.exportVideo()
            case "find": withAnimation(panelMotion) { model.showFind() }
            case "query": model.query = argument
            case "replace":
                model.replacement = argument
                withAnimation(Self.motion) { model.replaceAllMatches() }
            case "match": model.showMatch(step: Int(argument) ?? 1)
            case "split": withAnimation(Self.motion) { model.splitEditing(atCharacter: Int(argument)) }
            case "merge": withAnimation(Self.motion) { model.mergeEditingWithNext() }
            case "insert": withAnimation(Self.motion) { model.insertAfterEditing() }
            case "delete": withAnimation(Self.motion) { model.deleteEditing() }
            case "words": model.setCaptionWords(Int(argument) ?? 2)
            case "size": Double(argument).map { model.setCaptionScale($0 / 100) }
            case "face": CaptionFont(rawValue: argument).map(model.setCaptionFont)
            case "shadow": model.setCaptionShadow(argument != "off")
            case "stroke": model.setCaptionStroke(argument != "off")
            case "place":
                let parts = argument.split(separator: ",").compactMap { Double($0) }
                model.placeCaption(at: parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil, finished: true)
            case "drag":
                // `drag x,y>x,y`: a finger across the film, in shares of the picture.
                let ends = argument.split(separator: ">").map { $0.split(separator: ",").compactMap { Double($0) } }
                guard ends.count == 2, ends.allSatisfy({ $0.count == 2 }) else { break }
                let width = shownPictureSize.width
                let height = shownPictureSize.height
                beginPlacing(at: CGPoint(x: ends[0][0] * width, y: ends[0][1] * height))
                for step in 1...30 {
                    let t = Double(step) / 30
                    movePlacing(to: CGPoint(
                        x: (ends[0][0] + (ends[1][0] - ends[0][0]) * t) * width,
                        y: (ends[0][1] + (ends[1][1] - ends[0][1]) * t) * height
                    ))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                print("[editor] drag ended at \(model.style.position.map { "\($0.x),\($0.y)" } ?? "nil") snaps \(snaps)")
                endPlacing()
            case "style": withAnimation(panelMotion) { isStyling = true }
            case "unstyle": withAnimation(panelMotion) { isStyling = false }
            case "text": openExport(video: false)
            case "closepanels": closePanels()
            case "close": onClose()
            default: break
            }
        }
    }
    #endif

    // MARK: - Layouts

    private var wideLayout: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                    HStack(alignment: .center, spacing: 0) {
                        VStack(spacing: 18) {
                            picture
                            transport
                            if model.job.hasVideo {
                                CaptionStyleControls(model: model, palette: palette)
                                    .padding(.top, 6)
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .padding(.leading, 34)
                        .padding(.trailing, 22)
                        .padding(.bottom, 28)
                        .frame(width: proxy.size.width * 0.46)
                        VStack(spacing: 0) {
                            if model.isFinding {
                                FindBar(model: model, palette: palette, onClose: closeFind)
                                    .padding(.leading, 6)
                                    .padding(.top, 8)
                                    .transition(findTransition)
                            }
                            lyrics(fontSize: wideLyricSize, focus: 0.36)
                        }
                        .padding(.trailing, 22)
                    }
                }
                if showsExport {
                    // A click outside the card closes it.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closePanels() }
                    exportPanel(drawsCard: true)
                        .frame(width: 380)
                        .padding(.top, 58)
                        .padding(.trailing, 18)
                        .transition(cardTransition)
                }
            }
        }
        .animation(panelMotion, value: showsExport)
        .animation(panelMotion, value: model.isFinding)
    }

    private var findTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private func closeFind() {
        withAnimation(panelMotion) { model.hideFind() }
    }

    /// While a line is typed, the film steps back to a strip and the play bar leaves,
    /// so the line stays well clear of the keyboard. While the captions are styled, the
    /// lines leave and the film grows into their room, above the choices.
    private var compactLayout: some View {
        let isTyping = model.editingLineID != nil || model.isFinding
        return VStack(spacing: 0) {
            ZStack {
                header
                    .opacity(isStyling ? 0 : 1)
                    .allowsHitTesting(!isStyling)
                styleHeader
                    .opacity(isStyling ? 1 : 0)
                    .allowsHitTesting(isStyling)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            GeometryReader { proxy in
                VStack(spacing: isTyping ? 10 : 14) {
                    picture
                        .frame(maxHeight: isStyling ? .infinity : proxy.size.height * (isTyping ? 0.2 : 0.38))
                        .padding(.horizontal, 16)
                    if isStyling {
                        styleDock
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    } else {
                        if !isTyping {
                            transport
                                .padding(.horizontal, 20)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                        if model.isFinding {
                            FindBar(model: model, palette: palette, onClose: closeFind)
                                .padding(.horizontal, 14)
                                .transition(findTransition)
                        }
                        lyrics(fontSize: compactLyricSize, focus: 0.3)
                            .padding(.horizontal, 2)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 8)
            }
        }
        .animation(panelMotion, value: isTyping)
        .animation(panelMotion, value: isStyling)
        .interactiveDismissDisabled(isTyping || isStyling)
    }

    private var styleHeader: some View {
        ZStack {
            Text(localized("Estil dels subtítols"))
                .scaledFont(size: 15, weight: .semibold, relativeTo: .headline)
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            HStack {
                Spacer(minLength: 0)
                Button {
                    withAnimation(panelMotion) { isStyling = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 11, weight: .bold, relativeTo: .footnote)
                        Text(localized("Fet"))
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .fixedSize()
                    }
                    .foregroundStyle(palette.surface)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule(style: .continuous).fill(palette.ink))
                    .frame(minHeight: 44)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.trailing, 4)
            }
        }
        .frame(minHeight: 44)
    }

    /// The caption choices, docked at the foot of the screen like a sheet that stays.
    private var styleDock: some View {
        CaptionStyleControls(model: model, palette: palette)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .fill(palette.surface)
                    .shadow(color: palette.shadow.opacity(0.5), radius: 16, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            }
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.86, anchor: .topTrailing)).combined(with: .offset(y: -8)),
                removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing))
            )
    }

    private func closePanels() {
        withAnimation(panelMotion) { showsExport = false }
        model.dismissVideoExport()
    }

    // MARK: - Header

    private var closeButton: some View {
        Button {
            model.commit()
            onClose()
        } label: {
            Image(systemName: isCompact ? "chevron.down" : "xmark")
                .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(0.6))
                .frame(width: 30, height: 30)
                .background(Circle().fill(palette.well))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(localized("Tanca l'editor"))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isCompact { closeButton }
            VStack(alignment: isCompact ? .center : .leading, spacing: 2) {
                Text(model.job.title)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary)
                    .scaledFont(size: 12, relativeTo: .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink.opacity(0.52))
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            .animation(.easeOut(duration: 0.2), value: summary)

            glyphButton(symbol: "arrow.uturn.backward", label: localized("Desfés"), enabled: model.canUndo) {
                withAnimation(Self.motion) { model.undo() }
            }
            .help(localized("Desfés"))
            glyphButton(symbol: "magnifyingglass", label: localized("Cerca i substitueix"), enabled: !model.document.isEmpty || model.isFinding) {
                withAnimation(panelMotion) {
                    if model.isFinding { model.hideFind() } else { model.showFind() }
                }
            }
            .help(localized("Cerca i substitueix"))
            if isCompact, model.job.hasVideo {
                glyphButton(symbol: "textformat", label: localized("Estil dels subtítols"), enabled: true) {
                    model.commit()
                    withAnimation(panelMotion) {
                        model.hideFind()
                        isStyling = true
                    }
                }
            }
            Button {
                if showsExport { closePanels() } else { openExport(video: nil) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .body)
                    if !isCompact {
                        Text(localized("Exporta"))
                            .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                            .fixedSize()
                    }
                }
                .foregroundStyle(palette.surface)
                .padding(.horizontal, isCompact ? 0 : 16)
                .frame(width: isCompact ? 38 : nil, height: 38)
                .background(Capsule(style: .continuous).fill(palette.ink))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(model.document.isEmpty)
            .opacity(model.document.isEmpty ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.2), value: model.document.isEmpty)
            .accessibilityLabel(model.job.hasVideo ? localized("Exporta el vídeo o els subtítols") : localized("Exporta els subtítols"))
            if !isCompact { closeButton.padding(.leading, 4) }
        }
        .padding(.leading, leadingInset)
        #if os(macOS)
        // The strip is the window's title bar: it still moves the window.
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
        #endif
    }

    private var summary: String {
        let lines = model.document.lines.count
        let words = model.document.wordCount
        let counted = localized("\(words) paraules")
        if model.document.isEmpty { return localized("Sense veus") }
        // The phone's header has room for the count alone; the undo glyph shows a change.
        if isCompact { return counted }
        return model.job.isEdited
            ? "\(counted) · \(localized("corregit"))"
            : "\(counted) · \(localized("\(lines) frases"))"
    }

    private func glyphButton(symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        GlyphButton(symbol: symbol, ink: palette.ink, enabled: enabled, action: action)
            .accessibilityLabel(label)
    }

    /// Opens the export card, on the video (`true`), the subtitles and text (`false`),
    /// or where it was last left (`nil`).
    private func openExport(video: Bool?) {
        model.commit()
        if let video { exportsVideo = video }
        withAnimation(panelMotion) { showsExport = true }
    }

    // MARK: - Picture

    private var picture: some View {
        let size = model.pictureSize ?? CGSize(width: 16, height: 9)
        let placing = model.isPlacingCaption
        return ZStack {
            if model.job.hasVideo {
                Color.black
                PlayerSurface(player: model.player)
                if let pictureSize = model.pictureSize {
                    CaptionPreview(
                        clock: model.clock,
                        renderer: model.previewRenderer,
                        pictureSize: pictureSize,
                        // While styling, a pause between voices still shows a caption to judge.
                        showsNearest: placing || (isStyling && !model.isPlaying)
                    )
                    .allowsHitTesting(false)
                    // While the captions are dragged, thin lines mark the middles they
                    // hold to.
                    Rectangle()
                        .fill(LanguageCircle.orange)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .opacity(placing && snappedX ? 0.9 : 0)
                        .animation(.easeOut(duration: 0.12), value: placing && snappedX)
                        .allowsHitTesting(false)
                    Rectangle()
                        .fill(LanguageCircle.orange)
                        .frame(height: 1.5)
                        .frame(maxWidth: .infinity)
                        .opacity(placing && snappedY ? 0.9 : 0)
                        .animation(.easeOut(duration: 0.12), value: placing && snappedY)
                        .allowsHitTesting(false)
                }
            } else {
                palette.well
                Image(systemName: "waveform")
                    .scaledFont(size: 30, weight: .medium, relativeTo: .title)
                    .foregroundStyle(palette.ink.opacity(0.32))
            }
            if model.job.hasVideo { cornerPlayButton }
        }
        .aspectRatio(size, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { shownPictureSize = $0 }
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 18 : 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isCompact ? 18 : 20, style: .continuous)
                .strokeBorder(palette.ink.opacity(0.06))
        )
        .shadow(color: palette.shadow.opacity(0.6), radius: 18, y: 8)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlayback() }
        #if os(iOS)
        .gesture(CaptionDrag(
            isEnabled: canPlaceCaption,
            began: beginPlacing,
            moved: movePlacing,
            ended: endPlacing
        ))
        #else
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if grab == nil { beginPlacing(at: value.startLocation) }
                    movePlacing(to: value.location)
                }
                .onEnded { _ in endPlacing() },
            isEnabled: canPlaceCaption
        )
        #endif
        .sensoryFeedback(Self.snapFeedback, trigger: snaps)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.55), trigger: grabs)
        .animation(.easeInOut(duration: 0.3), value: model.pictureSize)
        .accessibilityElement()
        .accessibilityLabel(model.job.hasVideo ? localized("Vídeo") : localized("Àudio"))
        .accessibilityHint(canPlaceCaption ? localized("Arrossega el subtítol per moure'l") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.togglePlayback() }
    }

    /// A small play and pause glyph in the film's corner, clear of the captions.
    private var cornerPlayButton: some View {
        Button(action: model.togglePlayback) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.black.opacity(0.34)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .opacity(model.isPlacingCaption ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: model.isPlacingCaption)
        .accessibilityLabel(model.isPlaying ? localized("Pausa") : localized("Reprodueix"))
    }

    /// The iPhone moves captions while styling them (elsewhere a drag on the film would
    /// fight the sheet); the Mac at any time.
    private var canPlaceCaption: Bool {
        model.job.hasVideo && model.pictureSize != nil && (!isCompact || isStyling)
    }

    #if os(iOS)
    private static let snapFeedback = SensoryFeedback.impact(flexibility: .rigid, intensity: 1)
    #else
    private static let snapFeedback = SensoryFeedback.alignment
    #endif

    // MARK: - Placing the captions

    /// The text keeps the distance it had from the finger, so it never jumps to it.
    private func beginPlacing(at location: CGPoint) {
        guard let pictureSize = model.pictureSize, shownPictureSize.width > 0, shownPictureSize.height > 0 else { return }
        let text = model.captionTextFrame(in: pictureSize)
            ?? CGRect(x: 0.4, y: 0.78, width: 0.2, height: 0.06)
        grab = CGSize(
            width: text.midX * shownPictureSize.width - location.x,
            height: text.midY * shownPictureSize.height - location.y
        )
        grabbedHalf = CGSize(width: text.width / 2, height: text.height / 2)
        snappedX = abs(text.midX - 0.5) < 0.002
        snappedY = abs(text.midY - 0.5) < 0.002
        grabs += 1
    }

    /// Follows the finger, inside the picture; near the middle, across or down, the text
    /// holds to it with a tap until the finger pulls clearly away.
    private func movePlacing(to location: CGPoint) {
        guard let grab else { return }
        let width = shownPictureSize.width
        let height = shownPictureSize.height
        var x = Self.inside(location.x + grab.width, half: grabbedHalf.width * width, length: width)
        var y = Self.inside(location.y + grab.height, half: grabbedHalf.height * height, length: height)
        if Self.holds(&x, to: width / 2, snapped: &snappedX) { snaps += 1 }
        if Self.holds(&y, to: height / 2, snapped: &snappedY) { snaps += 1 }
        model.placeCaption(at: CGPoint(x: x / width, y: y / height), finished: false)
    }

    private func endPlacing() {
        guard grab != nil else { return }
        grab = nil
        model.placeCaption(at: model.style.position, finished: true)
    }

    private static func inside(_ value: CGFloat, half: CGFloat, length: CGFloat) -> CGFloat {
        guard half * 2 < length else { return length / 2 }
        return min(max(value, half), length - half)
    }

    /// Holds `value` to `middle` once it comes within 9 pt, until it leaves by 20 pt;
    /// true when it has just caught.
    private static func holds(_ value: inout CGFloat, to middle: CGFloat, snapped: inout Bool) -> Bool {
        let distance = abs(value - middle)
        if snapped {
            if distance > 20 { snapped = false } else { value = middle }
            return false
        }
        guard distance < 9 else { return false }
        snapped = true
        value = middle
        return true
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.surface)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(palette.ink))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(model.isPlaying ? localized("Pausa") : localized("Reprodueix"))
            PlaybackScrubber(model: model, clock: model.clock, palette: palette)
        }
    }

    // MARK: - Lines

    private func lyrics(fontSize: CGFloat, focus: CGFloat) -> some View {
        LyricsList(model: model, palette: palette, typeface: typeface, fontSize: fontSize, focus: focus, isCompact: isCompact)
    }

    // MARK: - Export panels

    private func exportPanel(drawsCard: Bool) -> some View {
        EditorExportPanel(
            model: model,
            palette: palette,
            typeface: typeface,
            exportsVideo: $exportsVideo,
            textActions: textActions,
            exportFormat: $exportFormat,
            videoActions: videoActions,
            drawsCard: drawsCard,
            onClose: closePanels
        )
    }

    #if os(iOS)
    private var exportSheet: some View {
        exportPanel(drawsCard: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                withAnimation(Self.motion) { exportSheetHeight = height }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .presentationDetents([.height(exportSheetHeight)])
            .presentationCornerRadius(28)
            .presentationBackground(palette.surface)
            .interactiveDismissDisabled(isRendering)
    }

    private var isRendering: Bool {
        if case .rendering = model.videoExport { return true }
        return false
    }
    #endif

    // MARK: - Keyboard

    /// Space plays and pauses, the arrows step five seconds, Return corrects the line
    /// being said and Escape closes, except while a line or a search is being typed;
    /// then Escape closes the search.
    private var keyboardCommands: some View {
        ZStack {
            if model.editingLineID == nil, model.isFinding {
                Button("") { closeFind() }
                    .keyboardShortcut(.cancelAction)
            }
            #if os(iOS)
            // A keyboard on the iPad or iPhone; the Mac's Edit menu has its own.
            Button("") { withAnimation(panelMotion) { model.showFind() } }
                .keyboardShortcut("f", modifiers: .command)
            #endif
            if model.editingLineID == nil, !model.isFinding {
                Button("") { model.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { model.seek(to: model.clock.time - 5) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.seek(to: model.clock.time + 5) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") {
                    if let index = model.currentIndex ?? (model.document.isEmpty ? nil : 0) {
                        model.edit(model.document.lines[index].id)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("") {
                    if showsExport { closePanels() } else { onClose() }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// A light grey glyph without a frame, as the reader's share glyph.
private struct GlyphButton: View {
    let symbol: String
    let ink: Color
    var enabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(ink.opacity(enabled ? (isHovered ? 0.7 : 0.42) : 0.16))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering }
        }
        .animation(.easeInOut(duration: 0.2), value: enabled)
    }
}

// MARK: - The lines

/// The lines of the video, kept around `focus` (a share of the height from the top) as
/// the film plays, unless the reader is scrolling them.
private struct LyricsList: View {
    @ObservedObject var model: SubtitleEditorModel
    let palette: SettingsBarPalette
    let typeface: ReadingTypeface
    let fontSize: CGFloat
    let focus: CGFloat
    let isCompact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedLine: Int?
    @State private var scrolledByHandAt = Date.distantPast
    @State private var hoveredLine: Int?
    /// The pending placement of the line being typed.
    @State private var placing: Task<Void, Never>?
    /// The line whose field has had the keyboard's focus.
    @State private var focusHeld: Int?

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.line.id) { item in
                            row(item.line, index: item.index)
                                .padding(.top, item.isFirst ? 0 : (item.line.startsParagraph ? fontSize * 1.0 : fontSize * 0.42))
                                .id(item.line.id)
                                .transition(rowTransition)
                        }
                    }
                    .padding(.top, proxy.size.height * focus)
                    .padding(.bottom, proxy.size.height * (1 - focus) - fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .decelerating { scrolledByHandAt = Date() }
                }
                .mask(fade(height: proxy.size.height, typing: isCompact && model.editingLineID != nil))
                // Until the first correction, a quiet line says what the lines are for;
                // it leaves once the film has moved on.
                .overlay(alignment: .topLeading) {
                    let showsHint = !model.job.isEdited && model.editingLineID == nil && !model.isFinding
                        && !model.document.isEmpty && (model.currentIndex ?? 0) < 2
                    Text(Self.hint)
                        .scaledFont(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.4))
                        .padding(.horizontal, 20)
                        .padding(.top, max(8, proxy.size.height * focus - fontSize * 2.2))
                        .opacity(showsHint ? 1 : 0)
                        .animation(.easeInOut(duration: 0.35), value: showsHint)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay {
                    if model.document.isEmpty {
                        Text(localized("Aquest vídeo no té veus."))
                            .font(Font(typeface.font(ofSize: fontSize * 0.8) as CTFont))
                            .foregroundStyle(palette.ink.opacity(0.4))
                    }
                }
                // Find goes to a line whatever the reader was doing with the lines.
                .onChange(of: model.focusRequest) { _, _ in
                    guard let id = model.focusLineID else { return }
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.9)) {
                        scroller.scrollTo(id, anchor: UnitPoint(x: 0, y: isCompact ? 0.22 : focus))
                    }
                }
                .onChange(of: model.currentIndex) { _, index in
                    // Playing or scrubbing, the lines follow, unless the reader is
                    // scrolling them.
                    guard let index, model.editingLineID == nil,
                          Date().timeIntervalSince(scrolledByHandAt) > 2.5,
                          index < model.document.lines.count else { return }
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.62, dampingFraction: 0.92)) {
                        scroller.scrollTo(model.document.lines[index].id, anchor: UnitPoint(x: 0, y: focus))
                    }
                }
                .onChange(of: model.editingLineID) { _, id in
                    focusHeld = nil
                    guard let id else {
                        focusedLine = nil
                        return
                    }
                    // The field is there once the row has redrawn.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        if model.editingLineID == id { focusedLine = id }
                    }
                    keepInView(id, scroller, after: 40)
                }
                // The keyboard rising (and the film stepping back) changes the room the
                // lines have: once it has settled, the line being typed is placed again,
                // so it never ends under the keyboard or above the top.
                .onChange(of: proxy.size.height) { _, _ in
                    if let id = model.editingLineID { keepInView(id, scroller, after: 180) }
                }
                // The film's preview shows the line as it is typed.
                .onChange(of: model.draft) { _, _ in
                    if model.editingLineID != nil { model.previewDraft() }
                }
                .onChange(of: focusedLine) { _, focused in
                    if let focused {
                        focusHeld = focused
                    } else if let held = focusHeld, model.editingLineID == held {
                        // Touching elsewhere keeps what was typed; a field that never had
                        // the focus (it was still appearing) has not been left.
                        focusHeld = nil
                        model.commit()
                    }
                }
            }
        }
    }

    #if os(iOS)
    static var hint: String { localized("Toca una frase per escoltar-la i corregir-la.") }
    #else
    static var hint: String { localized("Fes clic en una frase per escoltar-la i corregir-la.") }
    #endif

    /// A row: a line of the document, or the missing line being written after one.
    private struct Row {
        let line: SubtitleDocument.Line
        /// The line's place in the document; an added line takes the one before it.
        let index: Int
        let isFirst: Bool
    }

    private var rows: [Row] {
        var rows = model.document.lines.enumerated().map { Row(line: $0.element, index: $0.offset, isFirst: $0.offset == 0) }
        if let insertion = model.insertion, model.editingLineID == SubtitleEditorModel.Insertion.lineID {
            let position = insertion.after.flatMap { id in rows.firstIndex { $0.line.id == id } }.map { $0 + 1 } ?? 0
            let added = SubtitleDocument.Line(id: SubtitleEditorModel.Insertion.lineID, words: [])
            rows.insert(Row(line: added, index: max(0, position - 1), isFirst: position == 0), at: position)
            if position == 0, rows.count > 1 { rows[1] = Row(line: rows[1].line, index: rows[1].index, isFirst: false) }
        }
        return rows
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading))
    }

    /// The line being typed sits near the top of the lines on the iPhone, where the
    /// keyboard cannot reach it, and at the reading line on the Mac.
    private func keepInView(_ id: Int, _ scroller: ScrollViewProxy, after milliseconds: Int) {
        placing?.cancel()
        placing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled, model.editingLineID == id else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.9)) {
                scroller.scrollTo(id, anchor: UnitPoint(x: 0, y: isCompact ? 0.1 : focus))
            }
        }
    }

    /// The lines fade out at both edges; while a line is typed at the top on the
    /// iPhone, the top edge stays clear.
    private func fade(height: CGFloat, typing: Bool) -> some View {
        let edge = min(0.16, 56 / max(1, height))
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: typing ? 0.015 : edge),
                .init(color: .black, location: 1 - edge * 1.4),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private func row(_ line: SubtitleDocument.Line, index: Int) -> some View {
        let isEditing = model.editingLineID == line.id
        let isInsertion = line.id == SubtitleEditorModel.Insertion.lineID
        LyricRow(
            line: line,
            place: isInsertion ? .current : place(of: index),
            isEditing: isEditing,
            isInsertion: isInsertion,
            isHovered: hoveredLine == line.id,
            highlights: model.matchedWords[line.id] ?? [],
            canMerge: isEditing && model.canMergeEditing,
            canInsert: isEditing && model.canInsertAfterEditing,
            draft: $model.draft,
            focusedLine: $focusedLine,
            clock: model.clock,
            palette: palette,
            font: Font(typeface.font(ofSize: fontSize) as CTFont),
            fontSize: fontSize,
            showsKeys: !isCompact,
            onEdit: { model.edit(line.id) },
            onListen: { model.replayEditing() },
            onCommit: { withAnimation(SubtitleEditorView.motion) { model.commit() } },
            onNext: { withAnimation(SubtitleEditorView.motion) { model.commitAndEditNext() } },
            onCancel: { withAnimation(SubtitleEditorView.motion) { model.cancelEditing() } },
            onSplit: { offset in withAnimation(SubtitleEditorView.motion) { model.splitEditing(atCharacter: offset) } },
            onMerge: { withAnimation(SubtitleEditorView.motion) { model.mergeEditingWithNext() } },
            onInsert: { withAnimation(SubtitleEditorView.motion) { model.insertAfterEditing() } },
            onDelete: { withAnimation(SubtitleEditorView.motion) { model.deleteEditing() } }
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hoveredLine = hovering ? line.id : (hoveredLine == line.id ? nil : hoveredLine) }
        }
    }

    private func place(of index: Int) -> LyricRow.Place {
        // Before the first words, the first line waits in front.
        let current = model.currentIndex ?? 0
        if index == current { return .current }
        return index < current ? .past : .upcoming
    }
}

private struct LyricRow: View {
    enum Place { case past, current, upcoming }

    let line: SubtitleDocument.Line
    let place: Place
    let isEditing: Bool
    /// A line the recogniser missed, being written.
    let isInsertion: Bool
    let isHovered: Bool
    /// The words a search found, lit in the project's orange.
    let highlights: Set<Int>
    let canMerge: Bool
    let canInsert: Bool
    @Binding var draft: String
    var focusedLine: FocusState<Int?>.Binding
    let clock: PlaybackClock
    let palette: SettingsBarPalette
    let font: Font
    let fontSize: CGFloat
    let showsKeys: Bool
    let onEdit: () -> Void
    let onListen: () -> Void
    let onCommit: () -> Void
    let onNext: () -> Void
    let onCancel: () -> Void
    /// Cuts the line at a character of the draft (the cursor), or where it reads best.
    let onSplit: (Int?) -> Void
    let onMerge: () -> Void
    let onInsert: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The cursor waits at the end of the line, rather than the whole line selected.
    @State private var selection: TextSelection?

    private var restingOpacity: Double {
        if isHovered { return 0.72 }
        switch place {
        case .past: return 0.4
        case .current: return 1
        case .upcoming: return 0.26
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if isEditing {
                    field.transition(.opacity)
                } else {
                    Group {
                        if place == .current {
                            SpokenLine(words: line.words, highlights: highlights, clock: clock, ink: palette.ink, font: font)
                        } else if highlights.isEmpty {
                            Text(line.text)
                                .font(font)
                                .foregroundStyle(palette.ink.opacity(restingOpacity))
                        } else {
                            SpokenLine.text(line.words, highlights: highlights) { _ in palette.ink.opacity(restingOpacity) }
                                .font(font)
                        }
                    }
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onEdit)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, fontSize * 0.22)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.well)
                    .opacity(isEditing ? 1 : (isHovered ? 0.55 : 0))
            }
            if isEditing {
                editBar
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.3), value: place)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.86), value: isEditing)
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(isInsertion ? localized("Frase nova") : line.text)
        .accessibilityHint(localized("Toca per corregir aquesta frase"))
        .accessibilityAddTraits(place == .current ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onEdit() }
    }

    private var field: some View {
        TextField(isInsertion ? localized("Escriu el que es diu aquí") : localized("Frase"), text: $draft, selection: $selection, axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .lineSpacing(0)
            .foregroundStyle(palette.ink)
            .tint(LanguageCircle.orange)
            .focused(focusedLine, equals: line.id)
            .autocorrectionDisabled(false)
            #if os(iOS)
            .submitLabel(.done)
            #endif
            .onSubmit(onCommit)
            .onChange(of: draft) { _, text in
                // Return ends the line; a line break is never part of a subtitle.
                if text.contains("\n") {
                    draft = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    onCommit()
                }
            }
            .onKeyPress(.tab) {
                onNext()
                return .handled
            }
            .onKeyPress(.escape) {
                onCancel()
                return .handled
            }
            // Taking the focus selects the whole line; the cursor goes to its end instead.
            .onChange(of: focusedLine.wrappedValue) { _, focused in
                guard focused == line.id else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(30))
                    selection = TextSelection(insertionPoint: draft.endIndex)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hear it again, then what can be done to the line as a whole, then done. On the
    /// Mac, the keys that save, go on and undo, when there is room for them.
    private var editBar: some View {
        HStack(spacing: 6) {
            pill(localized("Escolta"), symbol: "arrow.counterclockwise", isPrimary: false, action: onListen)
            if !isInsertion {
                key("scissors", label: localized("Divideix la frase"), enabled: canSplit) { onSplit(cursorOffset) }
                key("rectangle.compress.vertical", label: localized("Uneix amb la frase següent"), enabled: canMerge, action: onMerge)
                key("text.insert", label: localized("Afegeix una frase que falta"), enabled: canInsert, action: onInsert)
            }
            key("trash", label: isInsertion ? localized("Descarta la frase nova") : localized("Esborra la frase"), enabled: true, action: onDelete)
            if showsKeys {
                ViewThatFits(in: .horizontal) {
                    Text(localized("↩ desa · ⇥ següent · esc desfà"))
                        .scaledFont(size: 11, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 6)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Spacer(minLength: 0)
            pill(localized("Fet"), symbol: "checkmark", isPrimary: true, action: onCommit)
        }
    }

    /// Two words or more to cut between.
    private var canSplit: Bool {
        draft.split(whereSeparator: \.isWhitespace).count > 1
    }

    /// Where the cursor sits in the draft, in characters.
    private var cursorOffset: Int? {
        guard let selection, case .selection(let range) = selection.indices,
              range.lowerBound >= draft.startIndex, range.lowerBound <= draft.endIndex else { return nil }
        return draft.distance(from: draft.startIndex, to: range.lowerBound)
    }

    /// A round glyph key in the well, for the line's own actions.
    private func key(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(enabled ? 0.75 : 0.22))
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.well))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.2), value: enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func pill(_ title: String, symbol: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .scaledFont(size: 11, weight: .bold, relativeTo: .footnote)
                Text(title)
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .fixedSize()
            }
            .foregroundStyle(isPrimary ? palette.surface : palette.ink.opacity(0.75))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(isPrimary ? palette.ink : palette.well))
            .frame(minHeight: 44)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
    }
}

/// The line being said: each word brightens as the voice reaches it.
private struct SpokenLine: View {
    let words: [SubtitleDocument.Word]
    var highlights: Set<Int> = []
    @ObservedObject var clock: PlaybackClock
    let ink: Color
    let font: Font

    var body: some View {
        let time = clock.time
        Self.text(words, highlights: highlights) { word in
            ink.opacity(0.42 + 0.58 * min(1, max(0, (time - word.start) / 0.12)))
        }
        .font(font)
    }

    /// The words in a row, each in its own colour; the ones a search found in orange.
    static func text(
        _ words: [SubtitleDocument.Word],
        highlights: Set<Int>,
        colour: (SubtitleDocument.Word) -> Color
    ) -> Text {
        words.enumerated().reduce(Text(verbatim: "")) { text, item in
            let word = Text(verbatim: item.element.text)
                .foregroundStyle(highlights.contains(item.offset) ? LanguageCircle.orange : colour(item.element))
            return item.offset == 0 ? Text("\(text)\(word)") : Text("\(text) \(word)")
        }
    }
}

// MARK: - Playback

/// A thin track the film's time fills, with times either side; dragging it scrubs.
private struct PlaybackScrubber: View {
    @ObservedObject var model: SubtitleEditorModel
    @ObservedObject var clock: PlaybackClock
    let palette: SettingsBarPalette

    @State private var dragging: Double?
    @State private var isHovered = false

    var body: some View {
        let duration = max(0.01, model.duration)
        let fraction = dragging ?? min(1, max(0, clock.time / duration))
        HStack(spacing: 10) {
            Text(Self.label(fraction * duration))
                .frame(minWidth: 38, alignment: .trailing)
            GeometryReader { proxy in
                let active = dragging != nil || isHovered
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(palette.well)
                        .frame(height: active ? 6 : 4)
                    Capsule(style: .continuous).fill(palette.ink.opacity(0.78))
                        .frame(width: max(active ? 6 : 4, proxy.size.width * fraction), height: active ? 6 : 4)
                    Circle()
                        .fill(palette.knob)
                        .shadow(color: palette.shadow, radius: 3, y: 1)
                        .overlay(Circle().strokeBorder(palette.hairline))
                        .frame(width: 14, height: 14)
                        .offset(x: proxy.size.width * fraction - 7)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let next = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            dragging = next
                            model.seek(to: next * duration, exact: false)
                        }
                        .onEnded { value in
                            let next = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            model.seek(to: next * duration)
                            dragging = nil
                        }
                )
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
            }
            .frame(height: 24)
            .onHover { hovering in isHovered = hovering }
            Text(Self.label(duration))
                .frame(minWidth: 38, alignment: .leading)
        }
        .scaledFont(size: 12, weight: .medium, relativeTo: .footnote)
        .monospacedDigit()
        .foregroundStyle(palette.ink.opacity(0.5))
        .accessibilityElement()
        .accessibilityLabel(localized("Temps"))
        .accessibilityValue("\(Self.label(clock.time)) / \(Self.label(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.seek(to: clock.time + 5)
            case .decrement: model.seek(to: clock.time - 5)
            @unknown default: break
            }
        }
    }

    /// "1:04", "1:02:09".
    static func label(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// The captions as they will be burnt in, drawn over the playing film by the same
/// renderer the export uses, at the size the film is shown.
private struct CaptionPreview: View {
    @ObservedObject var clock: PlaybackClock
    let renderer: CaptionRenderer
    let pictureSize: CGSize
    /// While the captions are being placed, the nearest one stands in during a pause.
    var showsNearest = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let time = clock.time
        Canvas { context, size in
            let scale = max(1, displayScale)
            let drawn = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            let layers = showsNearest
                ? renderer.nearestLayers(at: time, pictureSize: drawn)
                : renderer.layers(at: time, pictureSize: drawn)
            for layer in layers {
                let frame = CGRect(
                    x: layer.frame.minX / scale,
                    y: layer.frame.minY / scale,
                    width: layer.frame.width / scale,
                    height: layer.frame.height / scale
                )
                context.draw(Image(decorative: layer.image, scale: 1), in: frame)
            }
        }
    }
}

/// The film itself, without the system's controls.
#if canImport(AppKit)
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer = playerLayer
        }

        required init?(coder: NSCoder) { nil }
    }
}
#else
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The captions' drag on the iPhone. The film sits in a sheet, whose own pan would take a
/// downward drag; this pan goes first, and the sheet's waits for it to fail.
private struct CaptionDrag: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            began(location)
            moved(location)
        case .changed: moved(location)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer && other !== gestureRecognizer
        }
    }
}
#endif

// MARK: - The burnt-in copy

/// Making the copy with the subtitles in the picture: its progress, then the ways out.
struct VideoExportPanel: View {
    @ObservedObject var model: SubtitleEditorModel
    let palette: SettingsBarPalette
    /// The Mac's ways out for the finished file; the iPhone saves to Photos itself.
    var finishedActions: (URL) -> [ExportAction]
    var drawsCard = true
    /// Off inside the editor's export card, which has its own title and margins.
    var showsHeader = true
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader { header }
            Group {
                switch model.videoExport {
                case .idle:
                    idle.transition(step)
                case .rendering(let fraction):
                    rendering(fraction).transition(step)
                case .finished(let url):
                    finished(url).transition(step)
                case .failed(let message):
                    failed(message).transition(step)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(showsHeader ? (drawsCard ? 18 : 20) : 0)
        .background {
            if drawsCard {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(palette.hairline))
                    .shadow(color: palette.shadow, radius: 28, y: 14)
                    .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : ImportPanel.motion, value: phaseKey)
        .animation(.easeInOut(duration: 0.25), value: model.savedToPhotos)
        .animation(.easeInOut(duration: 0.25), value: model.photosError)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Vídeo amb subtítols"))
    }

    private var step: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.97, anchor: .top)),
                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
            )
    }

    private var phaseKey: Int {
        switch model.videoExport {
        case .idle: 0
        case .rendering: 1
        case .finished: 2
        case .failed: 3
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Vídeo amb subtítols"))
                    .scaledFont(size: 17, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .scaledFont(size: 13, relativeTo: .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink.opacity(0.56))
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(palette.well))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, -7)
            .padding(.trailing, -7)
            .accessibilityLabel(localized("Tanca"))
        }
    }

    /// "3840 × 2160 · la mateixa qualitat".
    static func detail(_ model: SubtitleEditorModel) -> String {
        guard let size = model.pictureSize else { return localized("La mateixa qualitat que l'original") }
        return "\(Int(size.width)) × \(Int(size.height)) · \(localized("la mateixa qualitat"))"
    }

    private var detail: String {
        guard let size = model.pictureSize else { return localized("La mateixa qualitat que l'original") }
        return "\(Int(size.width)) × \(Int(size.height)) · \(localized("la mateixa qualitat"))"
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("Els subtítols queden dins la imatge, tal com els veus a la vista prèvia."))
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            CardButton(title: localized("Fes el vídeo"), symbol: "captions.bubble", isPrimary: true, palette: palette) {
                model.exportVideo()
            }
        }
    }

    private func rendering(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    let percent = (fraction * 100).rounded(.down) / 100
                    Text(percent, format: .percent.precision(.fractionLength(0)))
                        .scaledFont(size: 28, weight: .semibold, relativeTo: .title)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink)
                        .contentTransition(.numericText(value: percent))
                        .animation(.easeOut(duration: 0.12), value: percent)
                    Spacer()
                    Text(localized("Cremant els subtítols…"))
                        .scaledFont(size: 12, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.52))
                }
                ImportProgressBar(fraction: fraction > 0.005 ? fraction : nil, palette: palette)
                    .animation(.linear(duration: 0.15), value: fraction)
            }
            CardButton(title: localized("Atura"), symbol: "stop.fill", isPrimary: false, palette: palette) {
                model.cancelVideoExport()
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .scaledFont(size: 14, weight: .bold, relativeTo: .body)
                    .foregroundStyle(palette.surface)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(palette.ink))
                VStack(alignment: .leading, spacing: 1) {
                    Text(localized("Vídeo a punt"))
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(palette.ink)
                    Text(url.lastPathComponent)
                        .scaledFont(size: 12, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.well))

            VStack(spacing: 8) {
                #if os(iOS)
                CardButton(
                    title: model.savedToPhotos ? localized("Desat a Fotos") : localized("Desa a Fotos"),
                    symbol: model.savedToPhotos ? "checkmark" : "photo.on.rectangle",
                    isPrimary: true,
                    palette: palette
                ) {
                    if !model.savedToPhotos { model.saveToPhotos() }
                }
                ShareLink(item: url) {
                    CardButtonLabel(title: localized("Comparteix"), symbol: "square.and.arrow.up", isPrimary: false, palette: palette)
                }
                .buttonStyle(PressableButtonStyle())
                if let error = model.photosError {
                    Text(error)
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                #else
                let actions = finishedActions(url)
                ForEach(actions.filter(\.isPrimary)) { action in
                    CardButton(title: action.title, symbol: action.symbol, isPrimary: true, palette: palette) { action.perform(.subtitles) }
                }
                HStack(spacing: 8) {
                    ForEach(actions.filter { !$0.isPrimary }) { action in
                        CardButton(title: action.title, symbol: action.symbol, isPrimary: false, palette: palette) { action.perform(.subtitles) }
                    }
                    ShareLink(item: url) {
                        CardButtonLabel(title: localized("Comparteix"), symbol: "square.and.arrow.up", isPrimary: false, palette: palette)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                #endif
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .scaledFont(size: 14, relativeTo: .body)
                .foregroundStyle(palette.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            CardButton(title: localized("Torna-ho a provar"), symbol: "arrow.clockwise", isPrimary: true, palette: palette) {
                model.exportVideo()
            }
        }
    }
}

/// The cards' capsule button: filled with ink when it is the main way on.
struct CardButton: View {
    let title: String
    let symbol: String
    let isPrimary: Bool
    let palette: SettingsBarPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CardButtonLabel(title: title, symbol: symbol, isPrimary: isPrimary, palette: palette)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
    }
}

struct CardButtonLabel: View {
    let title: String
    let symbol: String
    let isPrimary: Bool
    let palette: SettingsBarPalette

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                .fixedSize()
                .contentTransition(.opacity)
        }
        .foregroundStyle(isPrimary ? palette.surface : palette.ink)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(Capsule(style: .continuous).fill(isPrimary ? palette.ink : palette.well))
        .contentShape(Capsule(style: .continuous))
    }
}

// MARK: - Caption style

/// How the burnt-in captions look: words at a time, size, face, shadow and outline;
/// where they sit is set by dragging them on the film. Every choice shows at once in
/// the preview. The rows are wells whose lifted knob travels to the choice, as in the
/// settings bar.
struct CaptionStyleControls: View {
    @ObservedObject var model: SubtitleEditorModel
    let palette: SettingsBarPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let fonts = CaptionFont.available

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                row(localized("Paraules alhora")) {
                    StyleSegments(
                        options: CaptionStyle.wordChoices,
                        selected: model.style.wordsPerCue,
                        palette: palette,
                        label: { words in
                            Text(words == 0 ? localized("Frase") : "\(words)")
                                .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        },
                        accessibilityName: { $0 == 0 ? localized("Una frase alhora") : localized("\($0) paraules alhora") },
                        choose: model.setCaptionWords
                    )
                }
                row(localized("Mida")) { sizeStepper }
            }
            row(localized("Lletra")) { fontStrip }
            HStack(spacing: 8) {
                toggle(localized("Ombra"), isOn: model.style.shadow) { model.setCaptionShadow(!model.style.shadow) }
                toggle(localized("Contorn"), isOn: model.style.stroke) { model.setCaptionStroke(!model.style.stroke) }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.placeCaption(at: nil, finished: true) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.to.line")
                            .scaledFont(size: 11, weight: .bold, relativeTo: .footnote)
                        Text(localized("Al lloc"))
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .fixedSize()
                    }
                    .foregroundStyle(palette.ink.opacity(model.style.position == nil ? 0.3 : 0.75))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule(style: .continuous).fill(palette.well))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(model.style.position == nil)
                .animation(.easeInOut(duration: 0.2), value: model.style.position == nil)
                .accessibilityLabel(localized("Torna el subtítol al seu lloc"))
            }
            Text(localized("Arrossega el subtítol sobre el vídeo per moure'l."))
                .scaledFont(size: 12, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every face, each written in itself; the chosen one lifted.
    private var fontStrip: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(fonts, id: \.self) { font in
                        let isSelected = font == model.style.font
                        Button {
                            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : ImportPanel.selection) { model.setCaptionFont(font) }
                        } label: {
                            Text(verbatim: font.displayName)
                                .font(Font(font.font(ofSize: 15)))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(palette.ink.opacity(isSelected ? 1 : 0.6))
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .background {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(isSelected ? palette.knob : palette.well)
                                        .shadow(color: palette.shadow.opacity(isSelected ? 0.7 : 0), radius: 4, y: 1.5)
                                }
                                .outlinedWithoutColour(RoundedRectangle(cornerRadius: 11, style: .continuous), ink: palette.ink)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(font)
                        .accessibilityLabel(font.displayName)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            // The faces fade out at the strip's ends instead of being cut.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.05),
                        .init(color: .black, location: 0.95),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .onAppear { scroller.scrollTo(model.style.font, anchor: .center) }
            .onChange(of: model.style.font) { _, font in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { scroller.scrollTo(font, anchor: .center) }
            }
        }
    }

    private func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : "circle")
                    .scaledFont(size: 10, weight: .bold, relativeTo: .footnote)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .fixedSize()
            }
            .foregroundStyle(isOn ? palette.surface : palette.ink.opacity(0.65))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Capsule(style: .continuous).fill(isOn ? palette.ink : palette.well))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(0.52))
                .padding(.leading, 4)
            content()
        }
    }

    /// − and + on lifted keys either side of the size, in the same well as the choices
    /// beside it; held down, they keep stepping.
    private var sizeStepper: some View {
        let scale = model.style.scale
        return HStack(spacing: 2) {
            sizeKey("minus", label: localized("Més petit"), enabled: scale > CaptionStyle.scaleRange.lowerBound + 0.001, steps: -1)
            Text(Double(scale), format: .percent.precision(.fractionLength(0)))
                .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .contentTransition(.numericText(value: Double(scale)))
                .animation(.snappy(duration: 0.2), value: scale)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .accessibilityLabel(localized("Mida"))
            sizeKey("plus", label: localized("Més gran"), enabled: scale < CaptionStyle.scaleRange.upperBound - 0.001, steps: 1)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.well))
        .accessibilityElement(children: .contain)
    }

    private func sizeKey(_ symbol: String, label: String, enabled: Bool, steps: Int) -> some View {
        Button {
            model.stepCaptionSize(by: steps)
        } label: {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .bold, relativeTo: .body)
                .foregroundStyle(palette.ink.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 40, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(palette.knob)
                        .shadow(color: palette.shadow.opacity(enabled ? 0.7 : 0), radius: 4, y: 1.5)
                        .outlinedWithoutColour(RoundedRectangle(cornerRadius: 11, style: .continuous), ink: palette.ink)
                        .opacity(enabled ? 1 : 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.18), value: enabled)
        .accessibilityLabel(label)
    }
}

/// A well of equal choices with a lifted knob under the chosen one.
private struct StyleSegments<Option: Hashable, Label: View>: View {
    let options: [Option]
    let selected: Option
    let palette: SettingsBarPalette
    @ViewBuilder let label: (Option) -> Label
    let accessibilityName: (Option) -> String
    let choose: (Option) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selected
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : ImportPanel.selection) { choose(option) }
                } label: {
                    label(option)
                        .foregroundStyle(palette.ink.opacity(isSelected ? 1 : 0.5))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .matchedGeometryEffect(id: option, in: namespace, isSource: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityName(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(palette.knob)
                .shadow(color: palette.shadow.opacity(0.7), radius: 4, y: 1.5)
                .outlinedWithoutColour(RoundedRectangle(cornerRadius: 11, style: .continuous), ink: palette.ink)
                .matchedGeometryEffect(id: selected, in: namespace, isSource: false)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.well))
    }
}

// MARK: - Find and replace

/// Find and replace: a name misheard all through a video is put right at once. The
/// words found light up in orange in the lines; the arrows go from one to the next.
private struct FindBar: View {
    @ObservedObject var model: SubtitleEditorModel
    let palette: SettingsBarPalette
    let onClose: () -> Void

    private enum Field { case query, replacement }
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasQuery: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                well(symbol: "magnifyingglass") {
                    TextField(localized("Cerca al text"), text: $model.query)
                        .textFieldStyle(.plain)
                        .scaledFont(size: 15, relativeTo: .body)
                        .foregroundStyle(palette.ink)
                        .tint(LanguageCircle.orange)
                        .focused($focus, equals: .query)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        #endif
                        .onSubmit {
                            model.showMatch(step: 1)
                            focus = .query
                        }
                    if hasQuery {
                        Text(countLabel)
                            .scaledFont(size: 12, weight: .medium, relativeTo: .footnote)
                            .monospacedDigit()
                            .foregroundStyle(model.replacedCount ?? 0 > 0 ? LanguageCircle.orange : palette.ink.opacity(0.5))
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                step("chevron.up", label: localized("Anterior"), by: -1)
                step("chevron.down", label: localized("Següent"), by: 1)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.6))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(palette.well))
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(localized("Tanca la cerca"))
            }
            if hasQuery {
                HStack(spacing: 8) {
                    well(symbol: "arrow.turn.down.right") {
                        TextField(localized("Canvia per"), text: $model.replacement)
                            .textFieldStyle(.plain)
                            .scaledFont(size: 15, relativeTo: .body)
                            .foregroundStyle(palette.ink)
                            .tint(LanguageCircle.orange)
                            .focused($focus, equals: .replacement)
                            #if os(iOS)
                            .submitLabel(.done)
                            #endif
                            .onSubmit(replace)
                    }
                    Button(action: replace) {
                        Text(localized("Canvia-ho tot"))
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .fixedSize()
                            .foregroundStyle(palette.surface)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(Capsule(style: .continuous).fill(palette.ink))
                            .frame(minHeight: 44)
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(model.matches.isEmpty)
                    .opacity(model.matches.isEmpty ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.2), value: model.matches.isEmpty)
                    .accessibilityLabel(localized("Canvia-ho tot"))
                    .accessibilityHint(localized("Canvia totes les vegades que surt el text cercat"))
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : SubtitleEditorView.motion, value: hasQuery)
        .animation(.easeOut(duration: 0.2), value: countLabel)
        .task {
            // The bar has just risen: the search takes the keyboard.
            try? await Task.sleep(for: .milliseconds(80))
            focus = .query
        }
    }

    private var countLabel: String {
        if let replaced = model.replacedCount, replaced > 0 { return localized("Canviats: \(replaced)") }
        if model.matches.isEmpty { return localized("Cap") }
        if let index = model.matchIndex { return localized("\(index + 1) de \(model.matches.count)") }
        return "\(model.matches.count)"
    }

    private func replace() {
        guard !model.matches.isEmpty else { return }
        withAnimation(SubtitleEditorView.motion) { model.replaceAllMatches() }
    }

    private func well<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(0.42))
            content()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(palette.well))
        .frame(maxWidth: .infinity)
    }

    private func step(_ symbol: String, label: String, by step: Int) -> some View {
        let enabled = !model.matches.isEmpty
        return Button {
            model.showMatch(step: step)
        } label: {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(enabled ? 0.72 : 0.22))
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.2), value: enabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Export

/// The editor's one export card: the video with its subtitles burnt in, or the
/// subtitles (`.srt`) and the text on their own. A recording without a picture offers
/// only the second.
struct EditorExportPanel: View {
    @ObservedObject var model: SubtitleEditorModel
    let palette: SettingsBarPalette
    let typeface: ReadingTypeface
    @Binding var exportsVideo: Bool
    let textActions: [ExportAction]
    @Binding var exportFormat: TranscriptExportFormat
    let videoActions: (URL) -> [ExportAction]
    let drawsCard: Bool
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offersVideo: Bool { model.canExportVideo }
    private var showsVideo: Bool { offersVideo && exportsVideo }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if offersVideo {
                StyleSegments(
                    options: [true, false],
                    selected: showsVideo,
                    palette: palette,
                    label: { video in
                        HStack(spacing: 6) {
                            Image(systemName: video ? "film" : "captions.bubble")
                                .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                            Text(video ? localized("Vídeo") : localized("Subtítols i text"))
                                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    },
                    accessibilityName: { $0 ? localized("Vídeo amb subtítols") : localized("Subtítols i text") },
                    choose: { exportsVideo = $0 }
                )
            }
            ZStack(alignment: .top) {
                if showsVideo {
                    VideoExportPanel(model: model, palette: palette, finishedActions: videoActions, drawsCard: false, showsHeader: false)
                        .transition(switchTransition(leading: true))
                } else {
                    ExportPanel(
                        session: model.job.session,
                        palette: palette,
                        typeface: typeface,
                        storedFormat: $exportFormat,
                        actions: textActions,
                        render: model.job.rendered,
                        drawsCard: false,
                        showsHeader: false,
                        subtitlesCaption: subtitlesCaption,
                        onClose: onClose
                    )
                    .transition(switchTransition(leading: false))
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(drawsCard ? 18 : 20)
        .background {
            if drawsCard {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(palette.hairline))
                    .shadow(color: palette.shadow, radius: 28, y: 14)
                    .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.22) : ImportPanel.motion, value: showsVideo)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Exporta"))
    }

    private func switchTransition(leading: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: leading ? -18 : 18)),
                removal: .opacity.combined(with: .offset(x: leading ? -18 : 18))
            )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Exporta"))
                    .scaledFont(size: 17, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(palette.ink)
                Text(showsVideo ? VideoExportPanel.detail(model) : textDetail)
                    .scaledFont(size: 13, relativeTo: .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink.opacity(0.56))
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(palette.well))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, -7)
            .padding(.trailing, -7)
            .accessibilityLabel(localized("Tanca"))
        }
    }

    private var textDetail: String {
        let session = model.job.session
        return localized("\(session.wordCount) paraules · \(TranscriptExport.durationLabel(session.duration))")
    }

    /// The `.srt` holds the captions as the video shows them.
    private var subtitlesCaption: String {
        switch model.style.wordsPerCue {
        case 0: localized("Frase a frase, amb el seu temps")
        case 1: localized("Paraula per paraula, amb el seu temps")
        default: localized("\(model.style.wordsPerCue) paraules alhora, amb el seu temps")
        }
    }
}
