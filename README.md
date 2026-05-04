# ReadOutLoud

A small macOS SwiftUI app for opening a text, Markdown, or PDF file, placing the cursor anywhere in the rendered text, and reading aloud from that exact position.

## Features

- Open plain text or Markdown files
- Open PDF files and extract their text
- Click anywhere in the text to choose the reading start point
- Read aloud from the selected cursor location
- Stop and reset playback cleanly
- Zoom text in and out

## Notes

- PDF support currently reads extracted text rather than rendering the original PDF page layout.
- Text-based PDFs work best.
- Scanned or image-only PDFs are not OCR'd.

## Build

```bash
swift build
```

## Run

```bash
swift run
```
