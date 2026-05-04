import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ReadAloudApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var model = ReaderViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button("Open") {
                    model.openFile()
                }

                Button("Play") {
                    model.playFromCursor()
                }
                .disabled(!model.canPlay)

                Button("Stop") {
                    model.stop()
                }
                .disabled(!model.isSpeaking)

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        model.decreaseTextSize()
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Zoom out")
                    .disabled(!model.canZoomOut)

                    Button {
                        model.increaseTextSize()
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Zoom in")
                    .disabled(!model.canZoomIn)
                }

                if let fileName = model.fileName {
                    Text(fileName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ReaderTextView(
                renderedText: model.renderedText,
                fontSize: model.textSize,
                cursorLocation: $model.cursorLocation,
                spokenRange: $model.spokenRange,
                onUserCursorMove: {
                    model.handleUserCursorMove()
                }
            )
                .frame(minWidth: 720, idealWidth: 820, minHeight: 420, idealHeight: 520)
                .overlay {
                    if model.sourceText.isEmpty {
                        ContentUnavailableView(
                            "Open a Text, Markdown, or PDF File",
                            systemImage: "doc.text",
                            description: Text("Load a file, place the cursor anywhere in the rendered text, then press Play.")
                        )
                    }
                }

            if let message = model.statusMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

@MainActor
final class ReaderViewModel: NSObject, ObservableObject, NSSpeechSynthesizerDelegate, @unchecked Sendable {
    @Published var sourceText = ""
    @Published var renderedText = AttributedString("")
    @Published var cursorLocation = 0
    @Published var spokenRange: NSRange?
    @Published var statusMessage: String?
    @Published private(set) var textSize: CGFloat = 22
    @Published private(set) var fileName: String?
    @Published private(set) var isSpeaking = false

    private var speechSynthesizer: NSSpeechSynthesizer?
    private var playbackStartOffset = 0
    private var activeSynthesizerID: ObjectIdentifier?

    private let minTextSize: CGFloat = 14
    private let maxTextSize: CGFloat = 40

    var canPlay: Bool {
        !plainRenderedText.isEmpty
    }

    var canZoomIn: Bool {
        textSize < maxTextSize
    }

    var canZoomOut: Bool {
        textSize > minTextSize
    }

    private var plainRenderedText: String {
        String(renderedText.characters)
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text, .pdf]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let loadedText = try Self.loadText(from: url)
            resetPlaybackState()
            sourceText = loadedText
            renderedText = Self.renderMarkdown(from: loadedText)
            cursorLocation = 0
            fileName = url.lastPathComponent
            statusMessage = "Loaded \(url.lastPathComponent)"
        } catch {
            statusMessage = "Could not open file: \(error.localizedDescription)"
        }
    }

    func playFromCursor() {
        resetPlaybackState()

        let visibleText = plainRenderedText
        let safeIndex = max(0, min(cursorLocation, visibleText.count))
        let startIndex = visibleText.index(visibleText.startIndex, offsetBy: safeIndex)
        let textToRead = String(visibleText[startIndex...])

        guard textToRead.contains(where: { !$0.isWhitespace && !$0.isNewline }) else {
            statusMessage = "Nothing to read from the current cursor position."
            return
        }

        let synthesizer = NSSpeechSynthesizer()
        synthesizer.delegate = self
        let synthesizerID = ObjectIdentifier(synthesizer)
        activeSynthesizerID = synthesizerID

        playbackStartOffset = safeIndex
        spokenRange = NSRange(location: safeIndex, length: 0)

        if synthesizer.startSpeaking(textToRead) {
            speechSynthesizer = synthesizer
            isSpeaking = true
            statusMessage = "Reading from character \(safeIndex + 1)"
        } else {
            if activeSynthesizerID == synthesizerID {
                activeSynthesizerID = nil
            }
            statusMessage = "Could not start speech."
            isSpeaking = false
            spokenRange = nil
            speechSynthesizer = nil
        }
    }

    func stop() {
        resetPlaybackState()
        statusMessage = "Stopped."
    }

    func increaseTextSize() {
        textSize = min(textSize + 2, maxTextSize)
    }

    func decreaseTextSize() {
        textSize = max(textSize - 2, minTextSize)
    }

    func handleUserCursorMove() {
        resetPlaybackState()
        statusMessage = "Ready to read from character \(cursorLocation + 1)"
    }

    private func resetPlaybackState() {
        let synthesizer = speechSynthesizer
        activeSynthesizerID = nil
        speechSynthesizer = nil
        isSpeaking = false
        spokenRange = nil
        synthesizer?.stopSpeaking()
    }

    private static func renderMarkdown(from text: String) -> AttributedString {
        var result = AttributedString()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for index in lines.indices {
            let line = String(lines[index])
            let renderedLine = (try? AttributedString(
                markdown: line,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(line)
            result += renderedLine

            if index < lines.index(before: lines.endIndex) {
                result += AttributedString("\n")
            }
        }

        return result
    }

    private static func loadText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == UTType.pdf.preferredFilenameExtension {
            guard let document = PDFDocument(url: url) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let extractedText = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !extractedText.isEmpty else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }

            return extractedText
        }

        return try String(contentsOf: url, encoding: .utf8)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord characterRange: NSRange, of text: String) {
        guard activeSynthesizerID == ObjectIdentifier(sender) else {
            return
        }

        spokenRange = NSRange(
            location: playbackStartOffset + characterRange.location,
            length: characterRange.length
        )
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard activeSynthesizerID == ObjectIdentifier(sender) else {
            return
        }

        activeSynthesizerID = nil
        speechSynthesizer = nil
        isSpeaking = false
        spokenRange = nil

        if finishedSpeaking {
            statusMessage = "Finished reading."
        }
    }
}

struct ReaderTextView: NSViewRepresentable {
    let renderedText: AttributedString
    let fontSize: CGFloat
    @Binding var cursorLocation: Int
    @Binding var spokenRange: NSRange?
    let onUserCursorMove: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(cursorLocation: $cursorLocation, onUserCursorMove: onUserCursorMove)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        let textView = CursorTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 28, height: 12)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else {
            return
        }

        let visibleText = String(renderedText.characters)
        if textView.string != visibleText {
            let nsAttributed = Self.scaledAttributedString(from: renderedText, fontSize: fontSize)
            textView.textStorage?.setAttributedString(nsAttributed)
        } else if context.coordinator.lastAppliedFontSize != fontSize {
            let nsAttributed = Self.scaledAttributedString(from: renderedText, fontSize: fontSize)
            textView.textStorage?.setAttributedString(nsAttributed)
        }
        context.coordinator.lastAppliedFontSize = fontSize

        if let spokenRange {
            let clampedRange = NSRange(
                location: max(0, min(spokenRange.location, visibleText.count)),
                length: max(0, min(spokenRange.length, visibleText.count - min(spokenRange.location, visibleText.count)))
            )
            if textView.selectedRange() != clampedRange {
                context.coordinator.isApplyingProgrammaticSelection = true
                textView.setSelectedRange(clampedRange)
                textView.scrollRangeToVisible(clampedRange)
            }
        } else {
            let clampedLocation = max(0, min(cursorLocation, visibleText.count))
            if textView.selectedRange().location != clampedLocation || textView.selectedRange().length != 0 {
                context.coordinator.isApplyingProgrammaticSelection = true
                textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
            }
        }

        context.coordinator.updateCursorIndicator()
    }

    private static func scaledAttributedString(from text: AttributedString, fontSize: CGFloat) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let wholeRange = NSRange(location: 0, length: mutable.length)
        let fallbackFont = NSFont.systemFont(ofSize: fontSize)

        if mutable.length > 0 {
            mutable.enumerateAttribute(.font, in: wholeRange) { value, range, _ in
                let currentFont = (value as? NSFont) ?? fallbackFont
                let descriptor = currentFont.fontDescriptor
                let resizedFont = NSFont(descriptor: descriptor, size: fontSize) ?? fallbackFont
                mutable.addAttribute(.font, value: resizedFont, range: range)
            }
        } else {
            mutable.addAttribute(.font, value: fallbackFont, range: wholeRange)
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.15
        mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: wholeRange)

        return mutable
    }

    final class CursorTextView: NSTextView {
        let cursorIndicator = NSView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureCursorIndicator()
        }

        override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
            super.init(frame: frameRect, textContainer: container)
            configureCursorIndicator()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureCursorIndicator()
        }

        private func configureCursorIndicator() {
            cursorIndicator.wantsLayer = true
            cursorIndicator.layer?.backgroundColor = NSColor.systemRed.cgColor
            cursorIndicator.layer?.cornerRadius = 1.5
            cursorIndicator.isHidden = true
            addSubview(cursorIndicator)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var cursorLocation: Int
        let onUserCursorMove: () -> Void
        weak var textView: CursorTextView?
        var isApplyingProgrammaticSelection = false
        var lastAppliedFontSize: CGFloat = 0

        init(cursorLocation: Binding<Int>, onUserCursorMove: @escaping () -> Void) {
            _cursorLocation = cursorLocation
            self.onUserCursorMove = onUserCursorMove
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else {
                return
            }

            cursorLocation = min(textView.selectedRange().location, textView.string.count)

            if isApplyingProgrammaticSelection {
                isApplyingProgrammaticSelection = false
                updateCursorIndicator()
                return
            }

            updateCursorIndicator()
            onUserCursorMove()
        }

        func updateCursorIndicator() {
            guard let textView else {
                return
            }

            let selection = textView.selectedRange()
            guard selection.length <= 1 else {
                textView.cursorIndicator.isHidden = true
                return
            }

            let characterIndex = min(selection.location, textView.string.count)

            guard
                let layoutManager = textView.layoutManager,
                textView.textContainer != nil
            else {
                textView.cursorIndicator.isHidden = true
                return
            }

            guard layoutManager.numberOfGlyphs > 0 else {
                textView.cursorIndicator.isHidden = true
                return
            }

            let targetIndex = max(0, min(characterIndex, max(textView.string.count - 1, 0)))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: targetIndex, length: 0),
                actualCharacterRange: nil
            )
            let glyphIndex = max(0, min(glyphRange.location, max(layoutManager.numberOfGlyphs - 1, 0)))
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            var glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textView.textContainer!)

            if characterIndex == textView.string.count, characterIndex > 0 {
                let previousRange = NSRange(location: characterIndex - 1, length: 1)
                let previousGlyphRange = layoutManager.glyphRange(forCharacterRange: previousRange, actualCharacterRange: nil)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: previousGlyphRange.location, effectiveRange: nil)
                glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: previousGlyphRange.location, length: 1), in: textView.textContainer!)
            }

            lineRect.origin.x += textView.textContainerOrigin.x
            lineRect.origin.y += textView.textContainerOrigin.y
            glyphRect.origin.x += textView.textContainerOrigin.x
            glyphRect.origin.y += textView.textContainerOrigin.y

            guard lineRect.intersects(textView.visibleRect) || characterIndex == 0 else {
                textView.cursorIndicator.isHidden = true
                return
            }

            let indicatorWidth: CGFloat = 4
            let indicatorHeight = max(glyphRect.height, lineRect.height - 4, 18)
            textView.cursorIndicator.frame = NSRect(
                x: max(textView.textContainerOrigin.x, glyphRect.minX - 1),
                y: glyphRect.minY + max((glyphRect.height - indicatorHeight) / 2, -1),
                width: indicatorWidth,
                height: indicatorHeight
            )
            textView.cursorIndicator.isHidden = false
        }
    }
}
