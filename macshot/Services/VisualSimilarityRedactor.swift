import Cocoa
import Vision

enum CensorDrawMode: Int, CaseIterable {
    case all = 0
    case textOnly = 1
    case similar = 2

    static var current: CensorDrawMode {
        if UserDefaults.standard.object(forKey: "censorDrawMode") == nil,
           UserDefaults.standard.bool(forKey: "censorTextOnly") {
            return .textOnly
        }
        return CensorDrawMode(rawValue: UserDefaults.standard.integer(forKey: "censorDrawMode")) ?? .all
    }

    static func save(_ mode: CensorDrawMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "censorDrawMode")
        UserDefaults.standard.set(mode == .textOnly, forKey: "censorTextOnly")
    }
}

struct RecognizedToken {
    let text: String
    let rect: CGRect
    let lineIndex: Int
    let tokenIndex: Int
}

enum TextSimilarityRedactor {
    struct Match {
        let rect: CGRect
        let score: Double
    }

    private static let minSampleSide: CGFloat = 4
    private static let tokenOverlapThreshold: CGFloat = 0.35
    private static let matchPadding: CGFloat = 2

    static func findMatches(
        in image: NSImage,
        sampleRect: NSRect,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        completion: @escaping ([Match]) -> Void
    ) {
        let sampleRect = sampleRect.standardized.intersection(selectionRect)
        guard sampleRect.width >= minSampleSide, sampleRect.height >= minSampleSide else {
            completion([])
            return
        }
        guard let cgImage = cropToCGImage(
            screenshot: image,
            selectionRect: selectionRect,
            captureDrawRect: captureDrawRect
        ) else {
            completion([])
            return
        }

        VisionOCR.performTextRecognition(cgImage: cgImage) { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion([])
                return
            }
            let tokens = recognizedTokens(from: observations, selectionRect: selectionRect)
            completion(findMatches(in: tokens, sampleRect: sampleRect, selectionRect: selectionRect))
        }
    }

    static func findMatches(
        in tokens: [RecognizedToken],
        sampleRect: CGRect,
        selectionRect: CGRect,
        padding: CGFloat = matchPadding
    ) -> [Match] {
        let sampleRect = sampleRect.standardized.intersection(selectionRect)
        guard sampleRect.width >= minSampleSide, sampleRect.height >= minSampleSide else { return [] }
        let sortedTokens = tokens.sorted(by: tokenSort)
        let selected = sortedTokens.filter { overlapRatio($0.rect, sampleRect) >= tokenOverlapThreshold }
        let grouped = selected.groupedByLine().values.sorted { lhs, rhs in
            (lhs.first?.lineIndex ?? 0) < (rhs.first?.lineIndex ?? 0)
        }
        guard let target = grouped.first(where: { !$0.isEmpty }) else { return [] }
        let targetTexts = target.map(\.text)
        guard !targetTexts.isEmpty else { return [] }

        let lineGroups = sortedTokens.groupedByLine().values.map { $0.sorted(by: tokenSort) }
        var matches: [Match] = []
        for line in lineGroups {
            guard line.count >= targetTexts.count else { continue }
            let maxStart = line.count - targetTexts.count
            for start in 0...maxStart {
                let candidate = Array(line[start..<(start + targetTexts.count)])
                if sequenceMatches(candidate.map(\.text), targetTexts) {
                    let rect = unionRect(candidate.map(\.rect)).insetBy(dx: -padding, dy: -padding)
                    matches.append(Match(rect: rect, score: score(candidate.map(\.text), targetTexts)))
                }
            }
        }

        return matches.sorted { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 1 {
                return lhs.rect.minY > rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    static func buildRedactions(
        matches: [Match],
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect
    ) -> [Annotation] {
        guard !matches.isEmpty else { return [] }
        let groupID = UUID()
        let censorMode = CensorMode(rawValue: UserDefaults.standard.integer(forKey: "censorMode")) ?? .pixelate
        return matches.map { match in
            let rect = match.rect
            let ann = Annotation(
                tool: redactTool,
                startPoint: NSPoint(x: rect.minX, y: rect.minY),
                endPoint: NSPoint(x: rect.maxX, y: rect.maxY),
                color: color,
                strokeWidth: 0
            )
            ann.groupID = groupID
            ann.censorMode = censorMode
            if redactTool == .rectangle {
                ann.rectFillStyle = .fill
            } else if redactTool == .blur || redactTool == .pixelate {
                ann.sourceImage = sourceImage
                ann.sourceImageBounds = sourceImageBounds
            }
            ann.bakePixelate()
            return ann
        }
    }

    private static func recognizedTokens(
        from observations: [VNRecognizedTextObservation],
        selectionRect: CGRect
    ) -> [RecognizedToken] {
        var tokens: [RecognizedToken] = []
        for (lineIndex, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for (tokenIndex, range) in tokenRanges(in: candidate.string).enumerated() {
                guard let swiftRange = Range(range, in: candidate.string),
                      let box = try? candidate.boundingBox(for: swiftRange)
                else { continue }
                let rect = viewRect(from: box.boundingBox, selectionRect: selectionRect)
                tokens.append(RecognizedToken(
                    text: String(candidate.string[swiftRange]),
                    rect: rect,
                    lineIndex: lineIndex,
                    tokenIndex: tokenIndex
                ))
            }
        }
        return tokens
    }

    private static func tokenRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        let pattern = #"[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).map(\.range)
    }

    private static func cropToCGImage(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect
    ) -> CGImage? {
        let regionImage = NSImage(size: selectionRect.size, flipped: false) { _ in
            screenshot.draw(
                in: NSRect(
                    x: -selectionRect.origin.x,
                    y: -selectionRect.origin.y,
                    width: captureDrawRect.width,
                    height: captureDrawRect.height),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            return true
        }
        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.cgImage
    }

    private static func viewRect(from box: CGRect, selectionRect: CGRect) -> CGRect {
        let x = selectionRect.origin.x + box.origin.x * selectionRect.width
        let y = selectionRect.origin.y + box.origin.y * selectionRect.height
        return CGRect(
            x: x,
            y: y,
            width: box.width * selectionRect.width,
            height: box.height * selectionRect.height
        )
    }

    nonisolated private static func tokenSort(_ lhs: RecognizedToken, _ rhs: RecognizedToken) -> Bool {
        if lhs.lineIndex != rhs.lineIndex {
            return lhs.lineIndex < rhs.lineIndex
        }
        return lhs.tokenIndex < rhs.tokenIndex
    }

    private static func overlapRatio(_ rect: CGRect, _ sampleRect: CGRect) -> CGFloat {
        let intersection = rect.intersection(sampleRect)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        return (intersection.width * intersection.height) / area
    }

    private static func sequenceMatches(_ candidate: [String], _ target: [String]) -> Bool {
        guard candidate.count == target.count else { return false }
        for index in candidate.indices {
            guard tokenMatches(candidate[index], target[index]) else { return false }
        }
        return true
    }

    private static func tokenMatches(_ candidate: String, _ target: String) -> Bool {
        let candidate = normalize(candidate)
        let target = normalize(target)
        guard !candidate.isEmpty, !target.isEmpty else { return false }
        if candidate == target { return true }
        guard candidate.count >= 6, target.count >= 6 else { return false }
        let candidateDigits = digits(in: candidate)
        let targetDigits = digits(in: target)
        guard !candidateDigits.isEmpty, candidateDigits == targetDigits else { return false }
        return levenshteinDistance(candidate, target, maxDistance: 1) <= 1
    }

    private static func normalize(_ text: String) -> String {
        var value = text
            .lowercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "−", with: "-")

        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(
            CharacterSet(charactersIn: "-_=/()")
        )
        value = value.trimmingCharacters(in: trimSet)
        while value.hasSuffix(",") || value.hasSuffix(";") || value.hasSuffix(":") {
            value.removeLast()
        }
        return value
    }

    private static func digits(in text: String) -> String {
        String(text.filter(\.isNumber))
    }

    private static func score(_ candidate: [String], _ target: [String]) -> Double {
        var distance = 0
        for index in candidate.indices {
            distance += levenshteinDistance(
                normalize(candidate[index]),
                normalize(target[index]),
                maxDistance: 1
            )
        }
        return Double(distance)
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > maxDistance {
            return maxDistance + 1
        }
        var previous = Array(0...right.count)
        for (i, leftChar) in left.enumerated() {
            var current = [i + 1]
            var rowMin = current[0]
            for (j, rightChar) in right.enumerated() {
                let cost = leftChar == rightChar ? 0 : 1
                let value = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
                current.append(value)
                rowMin = min(rowMin, value)
            }
            if rowMin > maxDistance {
                return maxDistance + 1
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func unionRect(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { partial, rect in
            partial.union(rect)
        }
    }
}

private extension Array where Element == RecognizedToken {
    func groupedByLine() -> [Int: [RecognizedToken]] {
        Dictionary(grouping: self, by: \.lineIndex)
    }
}
