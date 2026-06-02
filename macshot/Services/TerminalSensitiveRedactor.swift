import Cocoa
import Vision

struct RecognizedLine {
    let text: String
    let rect: CGRect
    let lineIndex: Int
}

enum TerminalSensitiveRuleID: String, CaseIterable, Codable {
    case url
    case userHost
    case hostPort
    case ipv4
    case ipv6
    case mac
    case domain
    case sshShortHost
    case copyShortHost

    var title: String {
        switch self {
        case .url: return L("URL")
        case .userHost: return L("User@Host")
        case .hostPort: return L("Host:Port")
        case .ipv4: return L("IPv4 / CIDR")
        case .ipv6: return L("IPv6 / CIDR")
        case .mac: return L("MAC Address")
        case .domain: return L("Domain / FQDN")
        case .sshShortHost: return L("SSH short host")
        case .copyShortHost: return L("Copy short host")
        }
    }

    var example: String {
        switch self {
        case .url: return "https://api.example.com:8443/v1/status"
        case .userHost: return "root@prod.example.com"
        case .hostPort: return "api.example.com:8443"
        case .ipv4: return "10.12.0.8/24"
        case .ipv6: return "fe80::1ff:fe23:4567:890a"
        case .mac: return "0a:1b:2c:3d:4e:5f"
        case .domain: return "prod.example.com"
        case .sshShortHost: return "ssh db01"
        case .copyShortHost: return "scp dump.sql prod-api-1:/tmp/"
        }
    }
}

struct TerminalSensitiveCustomRule: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var pattern: String
    var example: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        example: String,
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.example = example
        self.enabled = enabled
    }
}

enum TerminalSensitiveRedactor {
    struct Match {
        let text: String
        let rect: CGRect
        let lineIndex: Int
    }

    static let customRegexDefaultsKey = "terminalSensitiveCustomRegexes"
    static let customRulesDefaultsKey = "terminalSensitiveCustomRules.v1"
    static let enabledBuiltinRuleIDsDefaultsKey = "terminalSensitiveEnabledBuiltinRuleIDs"

    private struct TextMatch {
        let range: NSRange
        let text: String
        let rank: Int
    }

    private static let padding: CGFloat = 2
    private static let schemePattern = #"(?:https?|ssh|sftp|ftp|git)://[^\s<>"']+"#
    private static let userHostPattern = #"\b[A-Za-z_][A-Za-z0-9_.-]*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9][A-Za-z0-9-]{0,62}\b"#
    private static let ipv4Pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b"#
    private static let ipv6Pattern = #"(?<![A-Za-z0-9_])(?:[A-Fa-f0-9]{0,4}:){2,}[A-Fa-f0-9:.]*(?:%[A-Za-z0-9_.-]+)?(?:/\d{1,3})?(?![A-Za-z0-9_])"#
    private static let macPattern = #"\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b"#
    private static let hostPortPattern = #"\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}:\d{1,5}\b|\b(?:\d{1,3}\.){3}\d{1,3}:\d{1,5}\b"#
    private static let domainPattern = #"\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\b"#
    private static let sshShortHostPattern = #"\b(?:ssh|mosh|telnet)\s+(?:-[^\s]+\s+)*(?:[A-Za-z_][A-Za-z0-9_.-]*@)?([A-Za-z][A-Za-z0-9-]*\d[A-Za-z0-9-]*|[A-Za-z][A-Za-z0-9-]*-[A-Za-z0-9-]+)\b"#
    private static let copyShortHostPattern = #"\b(?:scp|rsync)\b[^\n]*?\s(?:[A-Za-z_][A-Za-z0-9_.-]*@)?([A-Za-z][A-Za-z0-9-]*\d[A-Za-z0-9-]*|[A-Za-z][A-Za-z0-9-]*-[A-Za-z0-9-]+):[^\s]+"#

    private static let builtInRegexes: [(id: TerminalSensitiveRuleID, pattern: String, rank: Int)] = [
        (.url, schemePattern, 100),
        (.userHost, userHostPattern, 95),
        (.hostPort, hostPortPattern, 90),
        (.ipv4, ipv4Pattern, 85),
        (.ipv6, ipv6Pattern, 85),
        (.mac, macPattern, 85),
        (.domain, domainPattern, 70),
    ]

    static var allBuiltinRuleIDs: [TerminalSensitiveRuleID] {
        TerminalSensitiveRuleID.allCases
    }

    static func enabledBuiltinRuleIDs() -> Set<TerminalSensitiveRuleID> {
        guard let rawIDs = UserDefaults.standard.array(forKey: enabledBuiltinRuleIDsDefaultsKey) as? [String] else {
            return Set(allBuiltinRuleIDs)
        }
        return Set(rawIDs.compactMap(TerminalSensitiveRuleID.init(rawValue:)))
    }

    static func saveEnabledBuiltinRuleIDs(_ ids: Set<TerminalSensitiveRuleID>) {
        UserDefaults.standard.set(ids.map(\.rawValue), forKey: enabledBuiltinRuleIDsDefaultsKey)
    }

    static func customRegexText() -> String {
        UserDefaults.standard.string(forKey: customRegexDefaultsKey) ?? ""
    }

    static func customRegexPatterns(from text: String = customRegexText()) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func customRules(fromLegacyText text: String) -> [TerminalSensitiveCustomRule] {
        customRegexPatterns(from: text).enumerated().map { index, pattern in
            TerminalSensitiveCustomRule(
                name: "Custom \(index + 1)",
                pattern: pattern,
                example: "",
                enabled: true
            )
        }
    }

    static func customRules() -> [TerminalSensitiveCustomRule] {
        if let data = UserDefaults.standard.data(forKey: customRulesDefaultsKey),
           let rules = try? JSONDecoder().decode([TerminalSensitiveCustomRule].self, from: data) {
            return rules
        }

        let legacyText = customRegexText()
        let rules = customRules(fromLegacyText: legacyText)
        if !rules.isEmpty {
            saveCustomRules(rules)
        }
        return rules
    }

    static func saveCustomRules(_ rules: [TerminalSensitiveCustomRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: customRulesDefaultsKey)
        }
    }

    static func firstInvalidCustomRegex(in text: String) -> String? {
        for (index, pattern) in customRegexPatterns(from: text).enumerated() {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                return String(format: L("Invalid regex on line %d"), index + 1)
            }
        }
        return nil
    }

    static func firstInvalidCustomRule(in rules: [TerminalSensitiveCustomRule]) -> String? {
        for rule in rules where rule.enabled {
            let trimmedPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.isEmpty ? L("Untitled Rule") : name
            if trimmedPattern.isEmpty {
                return String(format: L("Rule pattern is required for %@"), displayName)
            }
            do {
                _ = try NSRegularExpression(pattern: trimmedPattern)
            } catch {
                return String(format: L("Invalid regex in %@"), displayName)
            }
        }
        return nil
    }

    static func redactTerminalSensitiveText(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        guard let cgImage = cropToCGImage(
            screenshot: screenshot,
            selectionRect: selectionRect,
            captureDrawRect: captureDrawRect
        ) else {
            completion([])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextRecognition(cgImage: cgImage) { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }
                let matches = matches(from: observations, selectionRect: selectionRect)
                let annotations = buildRedactions(
                    matches: matches,
                    redactTool: redactTool,
                    color: color,
                    sourceImage: sourceImage,
                    sourceImageBounds: sourceImageBounds
                )
                DispatchQueue.main.async { completion(annotations) }
            }
        }
    }

    static func findMatches(in lines: [RecognizedLine], customRegexes: [String]) -> [Match] {
        let customRules = customRegexes.map {
            TerminalSensitiveCustomRule(name: "", pattern: $0, example: "", enabled: true)
        }
        return findMatches(in: lines, enabledRuleIDs: Set(allBuiltinRuleIDs), customRules: customRules)
    }

    static func findMatches(
        in lines: [RecognizedLine],
        enabledRuleIDs: Set<TerminalSensitiveRuleID> = Set(allBuiltinRuleIDs),
        customRules: [TerminalSensitiveCustomRule]
    ) -> [Match] {
        var matches: [Match] = []
        for line in lines {
            let textMatches = filteredMatches(
                in: line.text,
                enabledRuleIDs: enabledRuleIDs,
                customRules: customRules
            )
            for textMatch in textMatches {
                guard let range = Range(textMatch.range, in: line.text) else { continue }
                let rect = rectForTextRange(textMatch.range, line: line)
                matches.append(Match(
                    text: String(line.text[range]),
                    rect: rect,
                    lineIndex: line.lineIndex
                ))
            }
        }
        return matches.sorted { lhs, rhs in
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            if abs(lhs.rect.minX - rhs.rect.minX) > 1 { return lhs.rect.minX < rhs.rect.minX }
            return lhs.rect.width > rhs.rect.width
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
            let rect = match.rect.insetBy(dx: -padding, dy: -padding)
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

    private static func matches(
        from observations: [VNRecognizedTextObservation],
        selectionRect: CGRect
    ) -> [Match] {
        var matches: [Match] = []
        let enabledRuleIDs = enabledBuiltinRuleIDs()
        let customRules = customRules()
        for (lineIndex, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let textMatches = filteredMatches(
                in: candidate.string,
                enabledRuleIDs: enabledRuleIDs,
                customRules: customRules
            )
            for textMatch in textMatches {
                guard let swiftRange = Range(textMatch.range, in: candidate.string),
                      let box = try? candidate.boundingBox(for: swiftRange)
                else { continue }
                matches.append(Match(
                    text: String(candidate.string[swiftRange]),
                    rect: viewRect(from: box.boundingBox, selectionRect: selectionRect),
                    lineIndex: lineIndex
                ))
            }
        }
        return matches
    }

    private static func filteredMatches(
        in text: String,
        enabledRuleIDs: Set<TerminalSensitiveRuleID>,
        customRules: [TerminalSensitiveCustomRule]
    ) -> [TextMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var matches: [TextMatch] = []

        for (id, pattern, rank) in builtInRegexes where enabledRuleIDs.contains(id) {
            matches.append(contentsOf: regexMatches(pattern: pattern, in: text, range: fullRange, rank: rank))
        }
        matches.append(contentsOf: strongContextShortHostnameMatches(
            in: text,
            range: fullRange,
            enabledRuleIDs: enabledRuleIDs
        ))
        for rule in customRules where rule.enabled
            && !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matches.append(contentsOf: regexMatches(pattern: rule.pattern, in: text, range: fullRange, rank: 110))
        }

        return removeOverlaps(matches.filter { shouldKeep($0, in: text) })
    }

    private static func regexMatches(
        pattern: String,
        in text: String,
        range: NSRange,
        rank: Int
    ) -> [TextMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        return regex.matches(in: text, range: range).compactMap { match in
            let resultRange = firstNonEmptyCapture(in: match) ?? match.range
            guard resultRange.length > 0,
                  let swiftRange = Range(resultRange, in: text)
            else { return nil }
            return TextMatch(range: resultRange, text: String(text[swiftRange]), rank: rank)
        }
    }

    private static func firstNonEmptyCapture(in match: NSTextCheckingResult) -> NSRange? {
        guard match.numberOfRanges > 1 else { return nil }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound, range.length > 0 {
                return range
            }
        }
        return nil
    }

    private static func strongContextShortHostnameMatches(
        in text: String,
        range: NSRange,
        enabledRuleIDs: Set<TerminalSensitiveRuleID>
    ) -> [TextMatch] {
        var matches: [TextMatch] = []
        if enabledRuleIDs.contains(.sshShortHost) {
            matches.append(contentsOf: regexMatches(pattern: sshShortHostPattern, in: text, range: range, rank: 80))
        }
        if enabledRuleIDs.contains(.copyShortHost) {
            matches.append(contentsOf: regexMatches(pattern: copyShortHostPattern, in: text, range: range, rank: 80))
        }
        return matches
    }

    private static func shouldKeep(_ match: TextMatch, in line: String) -> Bool {
        let value = match.text.trimmingCharacters(in: .punctuationCharacters)
        guard !value.isEmpty else { return false }
        if value.contains("://") || value.contains("@") { return true }
        if isMACLike(value) { return true }
        if isIPv4Like(value) { return isValidIPv4CIDR(value) }
        if isIPv6Like(value) { return isLikelyIPv6(value) }
        if value.contains(":") && isHostPortLike(value) { return isValidHostPort(value) }
        if value.contains(".") && !value.contains("://") && !value.contains("@") {
            return isDomain(value) && !isCommonFileName(value)
        }
        return true
    }

    private static func removeOverlaps(_ matches: [TextMatch]) -> [TextMatch] {
        let sorted = matches.sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }
        var kept: [TextMatch] = []
        for match in sorted {
            let overlaps = kept.contains { NSIntersectionRange($0.range, match.range).length > 0 }
            if !overlaps {
                kept.append(match)
            }
        }
        return kept.sorted { $0.range.location < $1.range.location }
    }

    private static func isIPv4Like(_ value: String) -> Bool {
        let ip = value.split(separator: "/", maxSplits: 1).first ?? ""
        return ip.split(separator: ".").count == 4 && ip.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func isIPv6Like(_ value: String) -> Bool {
        value.filter { $0 == ":" }.count >= 2
    }

    private static func isMACLike(_ value: String) -> Bool {
        let separator: Character = value.contains(":") ? ":" : "-"
        let parts = value.split(separator: separator)
        return parts.count == 6 && parts.allSatisfy {
            $0.count == 2 && $0.allSatisfy(\.isHexDigit)
        }
    }

    private static func isLikelyIPv6(_ value: String) -> Bool {
        let address = value
            .split(separator: "/", maxSplits: 1)
            .first?
            .split(separator: "%", maxSplits: 1)
            .first
            .map(String.init) ?? value
        guard address.contains(":") else { return false }
        let hextets = address.split(separator: ":", omittingEmptySubsequences: false)
        guard hextets.count >= 3, hextets.count <= 8 else { return false }
        let emptyCount = hextets.filter(\.isEmpty).count
        guard emptyCount <= 2 else { return false }
        return hextets.allSatisfy { part in
            part.isEmpty || (part.count <= 4 && part.allSatisfy(\.isHexDigit))
        }
    }

    private static func isValidIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        let octets = parts[0].split(separator: ".").map(String.init)
        guard octets.count == 4,
              octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false })
        else { return false }
        if parts.count == 2 {
            guard let cidr = Int(parts[1]), (0...32).contains(cidr) else { return false }
        }
        return true
    }

    private static func isHostPortLike(_ value: String) -> Bool {
        guard let colon = value.lastIndex(of: ":") else { return false }
        return value[value.index(after: colon)...].allSatisfy(\.isNumber)
    }

    private static func isValidHostPort(_ value: String) -> Bool {
        guard let colon = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: colon)...])
        else { return false }
        return (1...65535).contains(port)
    }

    private static func isDomain(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .punctuationCharacters)
        let labels = trimmed.split(separator: ".").map(String.init)
        guard labels.count >= 2,
              let tld = labels.last,
              tld.count >= 2,
              tld.count <= 63,
              tld.allSatisfy(\.isLetter)
        else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true
            else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isCommonFileName(_ value: String) -> Bool {
        let lower = value.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let blockedSuffixes = [
            ".log", ".yaml", ".yml", ".json", ".toml", ".xml", ".txt", ".md",
            ".conf", ".cfg", ".ini", ".sh", ".zsh", ".bash", ".tar.gz", ".tgz", ".zip",
        ]
        return blockedSuffixes.contains { lower.hasSuffix($0) }
    }

    private static func rectForTextRange(_ range: NSRange, line: RecognizedLine) -> CGRect {
        let length = max(1, (line.text as NSString).length)
        let startRatio = CGFloat(range.location) / CGFloat(length)
        let endRatio = CGFloat(range.location + range.length) / CGFloat(length)
        let x = line.rect.minX + line.rect.width * startRatio
        return CGRect(
            x: x,
            y: line.rect.minY,
            width: line.rect.width * max(0.01, endRatio - startRatio),
            height: line.rect.height
        )
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
}
