import Cocoa

/// Manages single-key overlay/editor tool shortcuts.
/// Stored in UserDefaults as a dictionary of action ID → key character.
/// An empty string means the shortcut is disabled (None).
enum ToolShortcutManager {

    /// All configurable overlay shortcut actions with their default keys.
    enum Action: String, CaseIterable {
        case pencil
        case arrow
        case line
        case rectangle
        case ellipse
        case marker
        case text
        case number
        case censor       // pixelate/blur tool
        case colorSampler
        case stamp
        case measure
        case loupe
        case openInEditor
        case pin
        case upload
        case copy
        case save
        case ocr
        case scrollCapture
        case beautify
        case invertColors
        case removeBackground
        case translate
        case undo
        case redo

        var label: String {
            switch self {
            case .pencil: return L("Pencil")
            case .arrow: return L("Arrow")
            case .line: return L("Line")
            case .rectangle: return L("Rectangle")
            case .ellipse: return L("Ellipse")
            case .marker: return L("Marker")
            case .text: return L("Text")
            case .number: return L("Number")
            case .censor: return L("Censor")
            case .colorSampler: return L("Color Picker")
            case .stamp: return L("Stamp")
            case .measure: return L("Measure")
            case .loupe: return L("Loupe")
            case .openInEditor: return L("Open in Editor")
            case .pin: return L("Pin")
            case .upload: return L("Upload")
            case .copy: return L("Copy")
            case .save: return L("Save")
            case .ocr: return L("OCR Text")
            case .scrollCapture: return L("Scroll Capture")
            case .beautify: return L("Beautify")
            case .invertColors: return L("Invert Colors")
            case .removeBackground: return L("Remove Background")
            case .translate: return L("Translate")
            case .undo: return L("Undo")
            case .redo: return L("Redo")
            }
        }

        var defaultKey: String {
            switch self {
            case .pencil: return "p"
            case .arrow: return "a"
            case .line: return "l"
            case .rectangle: return "r"
            case .ellipse: return "o"
            case .marker: return "m"
            case .text: return "t"
            case .number: return "n"
            case .censor: return "b"
            case .colorSampler: return "i"
            case .stamp: return "g"
            case .measure: return ""
            case .loupe: return ""
            case .openInEditor: return "e"
            case .pin: return "f"
            case .upload: return "u"
            case .copy: return ""
            case .save: return ""
            case .ocr: return ""
            case .scrollCapture: return ""
            case .beautify: return ""
            case .invertColors: return ""
            case .removeBackground: return ""
            case .translate: return ""
            case .undo: return ""
            case .redo: return ""
            }
        }
    }

    private static let defaultsKey = "overlayToolShortcuts"

    static func prepareCaches() {
        rebuildCaches()
    }

    /// Get the key character for an action. Empty string = disabled.
    static func key(for action: Action) -> String {
        if let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
           let key = dict[action.rawValue] {
            return key
        }
        return action.defaultKey
    }

    /// Set the key character for an action. Pass empty string to disable.
    static func setKey(_ key: String, for action: Action) {
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        dict[action.rawValue] = key
        UserDefaults.standard.set(dict, forKey: defaultsKey)
        rebuildCaches()
    }

    /// Build a reverse lookup: character → ToolbarButtonAction.
    /// Cached and invalidated when shortcuts change.
    static func lookupAction(for character: String) -> ToolbarButtonAction? {
        if _cachedLookup == nil { rebuildCaches() }
        return _cachedLookup?[character]
    }

    /// Display string for the shortcut bound to a toolbar action. Nil means no shortcut is assigned.
    static func displayString(forToolbarAction toolbarAction: ToolbarButtonAction) -> String? {
        if _cachedToolbarShortcutDisplay == nil { rebuildCaches() }

        let singleKey = toolbarAction.shortcutCacheKey.flatMap { _cachedToolbarShortcutDisplay?[$0] }
        let standardKey = standardShortcutDisplay(for: toolbarAction)
        switch (singleKey, standardKey) {
        case let (single?, standard?) where single != standard:
            return "\(single) / \(standard)"
        case let (single?, _):
            return single
        case let (nil, standard?):
            return standard
        default:
            return nil
        }
    }

    private static var _cachedLookup: [String: ToolbarButtonAction]?
    private static var _cachedToolbarShortcutDisplay: [String: String]?

    private static func rebuildCaches() {
        let shortcuts = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
        rebuildLookupCache(shortcuts: shortcuts)
        rebuildToolbarShortcutDisplayCache(shortcuts: shortcuts)
    }

    private static func configuredKey(for action: Action, shortcuts: [String: String]?) -> String {
        shortcuts?[action.rawValue] ?? action.defaultKey
    }

    private static func rebuildLookupCache(shortcuts: [String: String]?) {
        var lookup: [String: ToolbarButtonAction] = [:]
        for action in Action.allCases {
            let k = configuredKey(for: action, shortcuts: shortcuts)
            guard !k.isEmpty else { continue }
            lookup[k] = action.toolbarAction
        }
        _cachedLookup = lookup
    }

    private static func rebuildToolbarShortcutDisplayCache(shortcuts: [String: String]?) {
        var display: [String: String] = [:]
        for action in Action.allCases {
            let k = configuredKey(for: action, shortcuts: shortcuts)
            guard !k.isEmpty, let cacheKey = action.toolbarAction.shortcutCacheKey else { continue }
            display[cacheKey] = k.uppercased()
        }
        _cachedToolbarShortcutDisplay = display
    }

    private static func standardShortcutDisplay(for toolbarAction: ToolbarButtonAction) -> String? {
        switch toolbarAction {
        case .copy: return "⌘C"
        case .save: return "⌘S"
        case .undo: return "⌘Z"
        case .redo: return "⇧⌘Z"
        case .cancel: return "Esc"
        default: return nil
        }
    }

    /// Display string for a key (for UI).
    static func displayString(for action: Action) -> String {
        let k = key(for: action)
        return k.isEmpty ? L("None") : k.uppercased()
    }
}

private extension ToolShortcutManager.Action {
    var toolbarAction: ToolbarButtonAction {
        switch self {
        case .pencil: return .tool(.pencil)
        case .arrow: return .tool(.arrow)
        case .line: return .tool(.line)
        case .rectangle: return .tool(.rectangle)
        case .ellipse: return .tool(.ellipse)
        case .marker: return .tool(.marker)
        case .text: return .tool(.text)
        case .number: return .tool(.number)
        case .censor: return .tool(.pixelate)
        case .colorSampler: return .tool(.colorSampler)
        case .stamp: return .tool(.stamp)
        case .measure: return .tool(.measure)
        case .loupe: return .tool(.loupe)
        case .openInEditor: return .detach
        case .pin: return .pin
        case .upload: return .upload
        case .copy: return .copy
        case .save: return .save
        case .ocr: return .ocr
        case .scrollCapture: return .scrollCapture
        case .beautify: return .beautify
        case .invertColors: return .invertColors
        case .removeBackground: return .removeBackground
        case .translate: return .translate
        case .undo: return .undo
        case .redo: return .redo
        }
    }
}

private extension ToolbarButtonAction {
    var shortcutCacheKey: String? {
        switch self {
        case .tool(let tool): return "tool:\(tool.rawValue)"
        case .detach: return "detach"
        case .pin: return "pin"
        case .upload: return "upload"
        case .copy: return "copy"
        case .save: return "save"
        case .ocr: return "ocr"
        case .scrollCapture: return "scrollCapture"
        case .beautify: return "beautify"
        case .invertColors: return "invertColors"
        case .removeBackground: return "removeBackground"
        case .translate: return "translate"
        case .undo: return "undo"
        case .redo: return "redo"
        default:
            return nil
        }
    }
}
