import AppKit
import SwiftUI

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

                if let fileName = model.fileName {
                    Text(fileName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ReaderTextView(
                renderedText: model.renderedText,
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
                            "Open a Text or Markdown File",
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
    @Published private(set) var fileName: String?
    @Published private(set) var isSpeaking = false

    private var speechSynthesizer: NSSpeechSynthesizer?
    private var playbackStartOffset = 0

    var canPlay: Bool {
        !plainRenderedText.isEmpty
    }

    private var plainRenderedText: String {
        String(renderedText.characters)
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let loadedText = try String(contentsOf: url, encoding: .utf8)
            stop()
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
        stop()

        let visibleText = plainRenderedText
        let safeIndex = max(0, min(cursorLocation, visibleText.count))
        let startIndex = visibleText.index(visibleText.startIndex, offsetBy: safeIndex)
        let textToRead = String(visibleText[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !textToRead.isEmpty else {
            statusMessage = "Nothing to read from the current cursor position."
            return
        }

        let synthesizer = NSSpeechSynthesizer()
        synthesizer.delegate = self

        playbackStartOffset = safeIndex
        spokenRange = NSRange(location: safeIndex, length: 0)

        if synthesizer.startSpeaking(textToRead) {
            speechSynthesizer = synthesizer
            isSpeaking = true
            statusMessage = "Reading from character \(safeIndex + 1)"
        } else {
            statusMessage = "Could not start speech."
            isSpeaking = false
            spokenRange = nil
            speechSynthesizer = nil
        }
    }

    func stop() {
        speechSynthesizer?.stopSpeaking()
        speechSynthesizer = nil
        isSpeaking = false
        spokenRange = nil
    }

    func handleUserCursorMove() {
        guard isSpeaking else {
            return
        }

        playFromCursor()
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

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord characterRange: NSRange, of text: String) {
        spokenRange = NSRange(
            location: playbackStartOffset + characterRange.location,
            length: characterRange.length
        )
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        isSpeaking = false
        speechSynthesizer = nil
        spokenRange = nil
        if finishedSpeaking {
            statusMessage = "Finished reading."
        }
    }
}

struct ReaderTextView: NSViewRepresentable {
    let renderedText: AttributedString
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

        let textView = NSTextView()
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
        textView.textContainerInset = NSSize(width: 10, height: 12)
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
            let nsAttributed = NSAttributedString(renderedText)
            textView.textStorage?.setAttributedString(nsAttributed)
        }

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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var cursorLocation: Int
        let onUserCursorMove: () -> Void
        weak var textView: NSTextView?
        var isApplyingProgrammaticSelection = false

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
                return
            }

            onUserCursorMove()
        }
    }
}
