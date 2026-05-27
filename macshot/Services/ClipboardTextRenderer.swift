import Cocoa
import CryptoKit
import Foundation

enum ClipboardTextRenderer {
    struct Payload {
        let originalText: String
        let isMarkdownCandidate: Bool
        let identity: String
        var renderMarkdownEnabled: Bool
    }

    private static let maxCharacters = 5000
    private static let maxTextWidth: CGFloat = 720
    private static let maxTextHeight: CGFloat = 900
    private static let minTextWidth: CGFloat = 240
    private static let minTextHeight: CGFloat = 42
    private static let padding: CGFloat = 24
    private static let inlineMarkdownMarkers: Set<Character> = ["*", "_", "`", "[", "]", "<", "&"]

    private struct TextLayout {
        let width: CGFloat
        let height: CGFloat
    }

    static func clippedNonEmptyText(from text: String) -> String? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let clipped = clippedText(text, from: start)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? nil : clipped
    }

    static func makePayload(for text: String) -> Payload {
        let clipped = clippedText(text)
        return makePayload(forClippedText: clipped)
    }

    static func makePayload(forClippedText clipped: String) -> Payload {
        let isMarkdown = looksLikeMarkdown(clipped)
        return Payload(
            originalText: clipped,
            isMarkdownCandidate: isMarkdown,
            identity: textIdentity(for: clipped),
            renderMarkdownEnabled: isMarkdown
        )
    }

    static func render(_ payload: Payload) -> NSImage? {
        render(text: payload.originalText, asMarkdown: payload.isMarkdownCandidate && payload.renderMarkdownEnabled)
    }

    static func render(text: String, asMarkdown: Bool = false) -> NSImage? {
        let clipped = clippedText(text)
        let attributed = asMarkdown
            ? (markdownAttributedString(from: clipped) ?? plainAttributedString(clipped))
            : plainAttributedString(clipped)
        return renderCard(attributed)
    }

    private static func clippedText(_ text: String) -> String {
        clippedText(text, from: text.startIndex)
    }

    private static func clippedText(_ text: String, from start: String.Index) -> String {
        let end = text.index(start, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
        let clipped = String(text[start..<end])
        return end < text.endIndex ? clipped + "\n..." : clipped
    }

    private static func textIdentity(for text: String) -> String {
        let digest = Data(SHA256.hash(data: Data(text.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
        return "clipboard-text:\(digest)"
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        let prefix = firstContentPrefix(text, limit: 10)
        guard !prefix.isEmpty else { return false }
        if prefix.hasPrefix("<") { return false }
        let s = String(prefix)
        return s.hasPrefix("# ")
            || s.hasPrefix("##")
            || s.hasPrefix("```")
            || s.hasPrefix("> ")
            || s.hasPrefix("- ")
            || s.hasPrefix("* ")
            || s.hasPrefix("1. ")
            || s.hasPrefix("|")
    }

    private static func firstContentPrefix(_ text: String, limit: Int) -> Substring {
        let start = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
        return text[start...].prefix(limit)
    }

    private static func plainAttributedString(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    private static func markdownAttributedString(from text: String) -> NSAttributedString? {
        let output = NSMutableAttributedString()
        var inCodeBlock = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }

            if output.length > 0 {
                output.append(NSAttributedString(string: "\n"))
            }

            if inCodeBlock {
                output.append(NSAttributedString(string: rawLine, attributes: codeAttributes()))
                continue
            }

            let block = markdownBlock(from: rawLine)
            output.append(inlineMarkdown(block.text, attributes: block.attributes))
        }

        return output.length > 0 ? output : nil
    }

    private static func markdownBlock(from line: String) -> (text: String, attributes: [NSAttributedString.Key: Any]) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            return (String(trimmed.dropFirst(4)), textAttributes(font: .boldSystemFont(ofSize: 18)))
        }
        if trimmed.hasPrefix("## ") {
            return (String(trimmed.dropFirst(3)), textAttributes(font: .boldSystemFont(ofSize: 21)))
        }
        if trimmed.hasPrefix("# ") {
            return (String(trimmed.dropFirst(2)), textAttributes(font: .boldSystemFont(ofSize: 25)))
        }
        if trimmed.hasPrefix("> ") {
            return ("| " + trimmed.dropFirst(2), textAttributes(color: .secondaryLabelColor))
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return ("• " + trimmed.dropFirst(2), textAttributes())
        }
        if isOrderedListLine(trimmed) {
            return (String(trimmed), textAttributes())
        }
        return (line, textAttributes())
    }

    private static func inlineMarkdown(
        _ text: String,
        attributes baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard text.contains(where: { inlineMarkdownMarkers.contains($0) }) else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes(baseAttributes, range: fullRange)

        result.enumerateAttribute(NSAttributedString.Key("NSInlinePresentationIntent"), in: fullRange) { value, range, _ in
            guard let raw = value as? NSNumber else { return }
            var attrs: [NSAttributedString.Key: Any] = [:]
            if raw.uintValue & InlinePresentationIntent.stronglyEmphasized.rawValue != 0 {
                attrs[.font] = NSFont.boldSystemFont(ofSize: fontSize(in: baseAttributes))
            } else if raw.uintValue & InlinePresentationIntent.emphasized.rawValue != 0 {
                attrs[.font] = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: fontSize(in: baseAttributes)),
                    toHaveTrait: .italicFontMask
                )
            } else if raw.uintValue & InlinePresentationIntent.code.rawValue != 0 {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                attrs[.backgroundColor] = NSColor.separatorColor.withAlphaComponent(0.28)
            }
            if !attrs.isEmpty {
                result.addAttributes(attrs, range: range)
            }
        }
        result.removeAttribute(NSAttributedString.Key("NSInlinePresentationIntent"), range: fullRange)
        return result
    }

    private static func isOrderedListLine(_ line: String) -> Bool {
        var index = line.startIndex
        var hasDigit = false
        while index < line.endIndex, line[index].isNumber {
            hasDigit = true
            index = line.index(after: index)
        }
        guard hasDigit, index < line.endIndex, line[index] == "." else { return false }
        index = line.index(after: index)
        return index < line.endIndex && line[index].isWhitespace
    }

    private static func textAttributes(
        font: NSFont = .systemFont(ofSize: 16),
        color: NSColor = .labelColor
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 6
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    private static func codeAttributes() -> [NSAttributedString.Key: Any] {
        var attrs = textAttributes(font: .monospacedSystemFont(ofSize: 14, weight: .regular))
        attrs[.backgroundColor] = NSColor.separatorColor.withAlphaComponent(0.22)
        return attrs
    }

    private static func fontSize(in attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        (attrs[.font] as? NSFont)?.pointSize ?? 16
    }

    private static func renderCard(_ attributed: NSAttributedString) -> NSImage? {
        let textLayout = measuredLayout(for: attributed)
        let size = NSSize(width: textLayout.width + padding * 2, height: textLayout.height + padding * 2)
        guard size.width > 0, size.height > 0 else { return nil }

        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        let textRect = NSRect(x: padding, y: padding, width: textLayout.width, height: textLayout.height)
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        image.unlockFocus()
        return image.isValid && image.size.width > 0 && image.size.height > 0 ? image : nil
    }

    private static func measuredLayout(for attributed: NSAttributedString) -> TextLayout {
        let maxLayout = usedTextSize(for: attributed, width: maxTextWidth)
        let width = min(maxTextWidth, max(minTextWidth, ceil(maxLayout.width)))
        let height = min(maxTextHeight, max(minTextHeight, ceil(usedTextSize(for: attributed, width: width).height)))
        return TextLayout(width: width, height: height)
    }

    private static func usedTextSize(for attributed: NSAttributedString, width: CGFloat) -> NSSize {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: used.width, height: used.height)
    }
}
