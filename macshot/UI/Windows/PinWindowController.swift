import Cocoa
import UniformTypeIdentifiers
import Vision

@MainActor
protocol PinWindowControllerDelegate: AnyObject {
    func pinWindowDidClose(_ controller: PinWindowController)
}

private struct PinEditorBeautifyMargins {
    var left: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var top: CGFloat

    static let zero = PinEditorBeautifyMargins(left: 0, right: 0, bottom: 0, top: 0)

    static func canvas(config: BeautifyConfig, enabled: Bool) -> PinEditorBeautifyMargins {
        guard enabled else { return .zero }
        let shadowBleed = config.shadowRadius + BeautifyRenderer.shadowOffset(for: config.shadowRadius)
        let base = config.padding + shadowBleed
        let titleBar: CGFloat = (config.mode == .window && !config.isWindowSnap) ? 28 : 0
        return PinEditorBeautifyMargins(
            left: base,
            right: base,
            bottom: base,
            top: base + titleBar
        )
    }

    func scaled(x scaleX: CGFloat, y scaleY: CGFloat) -> PinEditorBeautifyMargins {
        PinEditorBeautifyMargins(
            left: left * scaleX,
            right: right * scaleX,
            bottom: bottom * scaleY,
            top: top * scaleY
        )
    }
}

private struct PinEditorLayout {
    var windowFrame: NSRect
    var imageViewRect: NSRect
}

@MainActor
class PinWindowController {

    weak var delegate: PinWindowControllerDelegate?

    let pinIdentity: String

    private var window: PinPanel?
    private var pinView: PinView?
    private var editorView: PinEditorView?
    private var preEditFrame: NSRect?
    private var ocrController: OCRResultController?
    private var currentImage: NSImage
    private var textPayload: ClipboardTextRenderer.Payload?
    private var renderedTextImagesByKey: [String: NSImage] = [:]
    private var isPreparingShare = false
    private let initialWindowSize: NSSize
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 5.0
    private static let editorChromeHeight: CGFloat = 104
    private static let toolbarButtonSize: CGFloat = 32
    private static let toolbarPadding: CGFloat = 4
    private static let toolbarSpacing: CGFloat = 2
    private static let editorHorizontalPadding: CGFloat = 8
    private static let editorToolbarStackHeight: CGFloat = 104

    init(
        image: NSImage,
        initialScreenRect: NSRect? = nil,
        textPayload: ClipboardTextRenderer.Payload? = nil,
        identity: String? = nil
    ) {
        self.currentImage = image
        self.textPayload = textPayload
        self.pinIdentity = identity ?? Self.identity(for: image)

        let size = image.size
        let screen = initialScreenRect.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        // Snipaste-style pinning: if the capture origin is known, paste back
        // over that screen area. Clipboard/history pins have no source rect,
        // so they use the normal centered placement.
        let maxW = screenFrame.width * 0.8
        let maxH = screenFrame.height * 0.8
        let sourceSize: NSSize
        if let rect = initialScreenRect,
           rect.height > 0,
           size.height > 0,
           abs((rect.width / rect.height) - (size.width / size.height)) < 0.01 {
            sourceSize = rect.size
        } else {
            sourceSize = size
        }
        let scale = min(1.0, min(maxW / sourceSize.width, maxH / sourceSize.height))
        let windowSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        self.initialWindowSize = windowSize
        if let textPayload {
            renderedTextImagesByKey[textRenderCacheKey(for: textPayload)] = image
        }

        let origin: NSPoint
        if let rect = initialScreenRect {
            origin = NSPoint(
                x: min(max(rect.minX, screenFrame.minX), screenFrame.maxX - windowSize.width),
                y: min(max(rect.minY, screenFrame.minY), screenFrame.maxY - windowSize.height)
            )
        } else {
            origin = NSPoint(
                x: screenFrame.midX - windowSize.width / 2,
                y: screenFrame.midY - windowSize.height / 2
            )
        }

        let panel = PinPanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.pinController = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        panel.becomesKeyOnlyIfNeeded = true

        let view = makePinView(image: image, frame: NSRect(origin: .zero, size: windowSize))
        panel.contentView = view
        self.window = panel
        self.pinView = view
    }

    static func identity(for image: NSImage) -> String {
        ImageIdentity.imageIdentity(for: image)
    }

    private func makePinView(image: NSImage, frame: NSRect) -> PinView {
        let view = PinView(image: image)
        view.frame = frame
        view.autoresizingMask = [.width, .height]
        view.showsBorder = window?.hasShadow ?? true
        view.onClose = { [weak self] in self?.close() }
        view.onEdit = { [weak self] in self?.toggleEditing() }
        view.onCopy = { [weak self] in self?.copyCurrentImage() }
        view.onSave = { [weak self] in self?.saveCurrentImage(showPanel: true) }
        view.onToggleShadow = { [weak self] in self?.toggleShadow() }
        view.onToggleMarkdownRendering = { [weak self] in self?.toggleMarkdownRendering() }
        view.onZoom = { [weak self] factor, viewPoint in
            self?.zoom(by: factor, around: viewPoint)
        }
        view.onResetZoom = { [weak self] in self?.resetZoom() }
        view.canToggleMarkdownRendering = textPayload?.isMarkdownCandidate == true
        view.markdownRenderingEnabled = textPayload?.renderMarkdownEnabled == true
        return view
    }

    private static func editorChromeRequiredWidth() -> CGFloat {
        let buttons = ToolbarLayout.bottomButtons(
            selectedTool: .arrow,
            selectedColor: .systemRed,
            beautifyEnabled: false,
            beautifyStyleIndex: 0,
            hasAnnotations: false,
            isRecording: false,
            effectsActive: false)
        let count = CGFloat(buttons.count)
        let bottomWidth = count > 0
            ? count * toolbarButtonSize + max(0, count - 1) * toolbarSpacing + toolbarPadding * 2
            : 0

        let strokeLabelWidth = (L("Stroke") as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium)]
        ).width
        let outlineWidth = max(
            50,
            (L("Outline") as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
            ).width + 20
        )
        let flipWidth = max(
            42,
            (L("Flip") as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
            ).width + 24
        )

        let arrowOptionsWidth: CGFloat =
            8
            + strokeLabelWidth + 4 + 100 + 4 + 28
            + 13 + CGFloat(LineStyle.allCases.count) * 36
            + 13 + CGFloat(ArrowStyle.allCases.count) * 30
            + 13 + outlineWidth + 2 + 18
            + 13 + flipWidth
            + 8

        return max(bottomWidth, arrowOptionsWidth) + editorHorizontalPadding * 2
    }

    private func zoom(by factor: CGFloat, around viewPoint: NSPoint) {
        guard editorView == nil, let window = window else { return }
        let oldFrame = window.frame
        let oldSize = oldFrame.size

        let currentScale = oldSize.width / initialWindowSize.width
        let newScale = min(Self.maxScale, max(Self.minScale, currentScale * factor))
        if abs(newScale - currentScale) < 0.001 { return }

        let newSize = NSSize(
            width: round(initialWindowSize.width * newScale),
            height: round(initialWindowSize.height * newScale)
        )

        let cursorScreenPoint = NSPoint(
            x: oldFrame.origin.x + viewPoint.x,
            y: oldFrame.origin.y + viewPoint.y
        )
        let fractionX = viewPoint.x / oldSize.width
        let fractionY = viewPoint.y / oldSize.height
        let newOrigin = NSPoint(
            x: cursorScreenPoint.x - fractionX * newSize.width,
            y: cursorScreenPoint.y - fractionY * newSize.height
        )

        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        pinView?.zoomPercent = Int(round(newScale * 100))
    }

    private func resetZoom() {
        guard editorView == nil, let window = window else { return }
        let oldFrame = window.frame
        let centerX = oldFrame.midX
        let centerY = oldFrame.midY
        let newOrigin = NSPoint(
            x: centerX - initialWindowSize.width / 2,
            y: centerY - initialWindowSize.height / 2
        )
        window.setFrame(NSRect(origin: newOrigin, size: initialWindowSize), display: true)
        pinView?.zoomPercent = 100
    }

    func show() {
        bringToFront()
    }

    var isClosed: Bool {
        window == nil
    }

    func bringToFront() {
        guard let window else { return }
        window.orderFrontRegardless()
        window.makeKey()
        if let editorView {
            window.makeFirstResponder(editorView)
        } else if let pinView {
            window.makeFirstResponder(pinView)
        }
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pinView = nil
        editorView = nil
        preEditFrame = nil
        delegate?.pinWindowDidClose(self)
    }

    func toggleEditing() {
        if editorView == nil {
            enterEditing()
        } else {
            finishEditing()
        }
    }

    private func enterEditing() {
        guard let window, editorView == nil else { return }
        let imageFrame = window.frame
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? imageFrame
        let placeToolbarBelow = imageFrame.minY - Self.editorToolbarStackHeight >= screenFrame.minY

        preEditFrame = imageFrame
        pinView = nil
        window.isMovableByWindowBackground = false

        let view = PinEditorView()
        view.toolbarPlacement = placeToolbarBelow ? .belowImage : .aboveImage
        view.screenshotImage = currentImage
        view.captureSourceImage = currentImage
        view.overlayDelegate = self
        view.onRequestChromeRelayout = { [weak self] in
            self?.relayoutEditorWindowPreservingImage()
        }

        let initialLayout = editorLayout(
            preservingImageScreenRect: imageFrame,
            toolbarPlacement: view.toolbarPlacement,
            beautifyEnabled: view.beautifyEnabled,
            beautifyConfig: view.beautifyConfig,
            chromeContentWidth: Self.editorChromeRequiredWidth(),
            screenFrame: screenFrame
        )

        window.contentAspectRatio = NSSize(width: 0, height: 0)
        window.setFrame(initialLayout.windowFrame, display: true)

        let container = NSView(frame: NSRect(origin: .zero, size: initialLayout.windowFrame.size))
        container.autoresizingMask = [.width, .height]

        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        view.imageViewRect = initialLayout.imageViewRect
        view.chromeParentView = container

        container.addSubview(view)
        view.applySelection(NSRect(origin: .zero, size: currentImage.size))
        window.contentView = container
        editorView = view
        preEditFrame = imageScreenRect(windowFrame: initialLayout.windowFrame, imageViewRect: initialLayout.imageViewRect)
        relayoutEditorWindowPreservingImage(imageScreenRect: imageFrame)
        window.makeFirstResponder(view)
    }

    private func relayoutEditorWindowPreservingImage(imageScreenRect explicitImageRect: NSRect? = nil) {
        guard let window, let view = editorView else { return }
        let imageRect = explicitImageRect ?? currentEditorImageScreenRect() ?? preEditFrame ?? window.frame
        let screenFrame = window.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(imageRect) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? imageRect
        let layout = editorLayout(
            preservingImageScreenRect: imageRect,
            toolbarPlacement: view.toolbarPlacement,
            beautifyEnabled: view.beautifyEnabled,
            beautifyConfig: view.beautifyConfig,
            chromeContentWidth: view.editorChromeContentWidth(fallback: Self.editorChromeRequiredWidth()),
            screenFrame: screenFrame
        )

        window.setFrame(layout.windowFrame, display: true)
        window.contentView?.setFrameSize(layout.windowFrame.size)
        view.frame = NSRect(origin: .zero, size: layout.windowFrame.size)
        view.imageViewRect = layout.imageViewRect
        view.repositionToolbars()
        view.needsDisplay = true
        preEditFrame = imageScreenRect(windowFrame: layout.windowFrame, imageViewRect: layout.imageViewRect)
    }

    private func currentEditorImageScreenRect() -> NSRect? {
        guard let window, let view = editorView else { return nil }
        return imageScreenRect(windowFrame: window.frame, imageViewRect: view.imageViewRect)
    }

    private func imageScreenRect(windowFrame: NSRect, imageViewRect: NSRect) -> NSRect {
        NSRect(
            x: windowFrame.minX + imageViewRect.minX,
            y: windowFrame.minY + imageViewRect.minY,
            width: imageViewRect.width,
            height: imageViewRect.height
        )
    }

    private func editorLayout(
        preservingImageScreenRect imageScreenRect: NSRect,
        toolbarPlacement: PinEditorView.ToolbarPlacement,
        beautifyEnabled: Bool,
        beautifyConfig: BeautifyConfig,
        chromeContentWidth: CGFloat,
        screenFrame: NSRect
    ) -> PinEditorLayout {
        let scaleX = imageScreenRect.width / max(currentImage.size.width, 1)
        let scaleY = imageScreenRect.height / max(currentImage.size.height, 1)
        let margins = PinEditorBeautifyMargins
            .canvas(config: beautifyConfig, enabled: beautifyEnabled)
            .scaled(x: scaleX, y: scaleY)

        let previewWidth = imageScreenRect.width + margins.left + margins.right
        let contentCoreWidth = max(previewWidth, chromeContentWidth)
        let contentWidth = contentCoreWidth + Self.editorHorizontalPadding * 2
        let previewX = Self.editorHorizontalPadding + max(0, (contentCoreWidth - previewWidth) / 2)
        let imageX = previewX + margins.left

        let previewHeight = imageScreenRect.height + margins.bottom + margins.top
        let contentHeight = previewHeight + Self.editorToolbarStackHeight
        let previewY: CGFloat
        switch toolbarPlacement {
        case .belowImage:
            previewY = Self.editorToolbarStackHeight
        case .aboveImage:
            previewY = 0
        }
        let imageY = previewY + margins.bottom

        let imageViewRect = NSRect(
            x: imageX,
            y: imageY,
            width: imageScreenRect.width,
            height: imageScreenRect.height
        )
        var frame = NSRect(
            x: imageScreenRect.minX - imageViewRect.minX,
            y: imageScreenRect.minY - imageViewRect.minY,
            width: contentWidth,
            height: contentHeight
        )
        frame.origin = clampedEditorOrigin(frame: frame, visibleFrame: screenFrame)
        let adjustedImageRect = NSRect(
            x: frame.minX + imageViewRect.minX,
            y: frame.minY + imageViewRect.minY,
            width: imageViewRect.width,
            height: imageViewRect.height
        )
        let adjustedImageViewRect = NSRect(
            x: adjustedImageRect.minX - frame.minX,
            y: adjustedImageRect.minY - frame.minY,
            width: adjustedImageRect.width,
            height: adjustedImageRect.height
        )
        return PinEditorLayout(windowFrame: frame, imageViewRect: adjustedImageViewRect)
    }

    private func clampedEditorOrigin(frame: NSRect, visibleFrame: NSRect) -> NSPoint {
        var origin = frame.origin
        if frame.width <= visibleFrame.width {
            if origin.x < visibleFrame.minX {
                origin.x = visibleFrame.minX
            } else if origin.x + frame.width > visibleFrame.maxX {
                origin.x = visibleFrame.maxX - frame.width
            }
        } else {
            origin.x = visibleFrame.minX
        }
        if frame.height <= visibleFrame.height {
            if origin.y < visibleFrame.minY {
                origin.y = visibleFrame.minY
            } else if origin.y + frame.height > visibleFrame.maxY {
                origin.y = visibleFrame.maxY - frame.height
            }
        } else {
            origin.y = visibleFrame.minY
        }
        return origin
    }

    private func finishEditing() {
        guard let window, let editorView else { return }
        editorView.commitTextFieldIfNeeded()
        let restoreFrame = editorView.committedPinScreenRect(windowFrame: window.frame)
            ?? preEditFrame
            ?? NSRect(origin: window.frame.origin, size: initialWindowSize)
        if let image = editorView.renderCommittedPinImage() {
            currentImage = image
        }

        preEditFrame = nil
        window.setFrame(restoreFrame, display: true)
        let view = makePinView(
            image: currentImage,
            frame: NSRect(origin: .zero, size: restoreFrame.size))
        window.contentView = view
        self.editorView = nil
        self.pinView = view
        window.isMovableByWindowBackground = true
        window.contentAspectRatio = currentImage.size
        window.makeFirstResponder(view)
    }

    private func toggleShadow() {
        let enabled = !(window?.hasShadow ?? true)
        window?.hasShadow = enabled
        pinView?.showsBorder = enabled
    }

    private func toggleMarkdownRendering() {
        if editorView != nil { finishEditing() }
        guard var payload = textPayload, payload.isMarkdownCandidate else { return }
        payload.renderMarkdownEnabled.toggle()
        guard let image = renderedTextImage(for: payload), let window else { return }

        let oldFrame = window.frame
        currentImage = image
        textPayload = payload

        let newHeight = oldFrame.width * image.size.height / max(image.size.width, 1)
        let newSize = NSSize(width: oldFrame.width, height: max(1, newHeight))
        let newOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.midY - newSize.height / 2
        )

        window.contentAspectRatio = image.size
        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: false)
        let view = makePinView(image: image, frame: NSRect(origin: .zero, size: newSize))
        window.contentView = view
        pinView = view
        window.makeFirstResponder(view)
    }

    private func renderedTextImage(for payload: ClipboardTextRenderer.Payload) -> NSImage? {
        let key = textRenderCacheKey(for: payload)
        if let cached = renderedTextImagesByKey[key] {
            return cached
        }
        guard let image = ClipboardTextRenderer.render(payload) else { return nil }
        renderedTextImagesByKey[key] = image
        return image
    }

    private func textRenderCacheKey(for payload: ClipboardTextRenderer.Payload) -> String {
        "\(payload.identity)|markdown:\(payload.renderMarkdownEnabled)"
    }

    private func copyCurrentImage() {
        if editorView != nil { finishEditing() }
        ImageEncoder.copyToClipboard(currentImage)
    }

    private func saveCurrentImage(showPanel: Bool) {
        if editorView != nil { finishEditing() }
        let image = currentImage
        if showPanel {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [ImageEncoder.utType]
            savePanel.nameFieldStringValue = FilenameFormatter.defaultImageFilename()
            savePanel.directoryURL = SaveDirectoryAccess.directoryHint()
            savePanel.begin { response in
                guard response == .OK, let url = savePanel.url else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let imageData = ImageEncoder.encode(image) else { return }
                    try? imageData.write(to: url)
                }
            }
        } else {
            let dirURL = SaveDirectoryAccess.resolve()
            let fileURL = dirURL.appendingPathComponent(FilenameFormatter.defaultImageFilename())
            DispatchQueue.global(qos: .userInitiated).async {
                defer { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                guard let imageData = ImageEncoder.encode(image) else { return }
                try? imageData.write(to: fileURL)
            }
        }
    }

    private func shareCurrentImage(anchorView: NSView?) {
        if editorView != nil { finishEditing() }
        guard !isPreparingShare else { return }
        isPreparingShare = true
        let image = currentImage
        let filename = FilenameFormatter.defaultImageFilename()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let imageData = ImageEncoder.encode(image) else {
                DispatchQueue.main.async { self?.isPreparingShare = false }
                return
            }
            let tempURL = TmpScratchDirectory.makeURL(filename: filename)
            try? imageData.write(to: tempURL)
            DispatchQueue.main.async { [weak self, weak anchorView] in
                guard let self else { return }
                self.isPreparingShare = false
                let picker = NSSharingServicePicker(items: [tempURL])
                if let anchorView {
                    picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minX)
                } else if let view = self.pinView ?? self.editorView {
                    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                }
            }
        }
    }

    private func uploadCurrentImage() {
        if editorView != nil { finishEditing() }
        (NSApp.delegate as? AppDelegate)?.uploadImage(currentImage)
    }

    private func requestOCR() {
        if editorView != nil { finishEditing() }
        guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextRecognition(cgImage: cgImage) { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation])?.compactMap {
                    $0.topCandidates(1).first?.string
                } ?? []
                let text = lines.joined(separator: "\n")
                DispatchQueue.main.async {
                    let action = UserDefaults.standard.integer(forKey: "ocrAction")
                    if (action == 0 || action == 2) && !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    if action == 0 || action == 1 {
                        let controller = OCRResultController(text: text, image: self.currentImage)
                        self.ocrController = controller
                        controller.show()
                    }
                }
            }
        }
    }
}

// MARK: - OverlayViewDelegate

extension PinWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidCancel() { finishEditing() }
    func overlayViewDidConfirm() { copyCurrentImage() }
    func overlayViewDidRequestSave() { saveCurrentImage(showPanel: true) }
    func overlayViewDidRequestFileSave() { saveCurrentImage(showPanel: false) }
    func overlayViewDidRequestPin() { finishEditing(); bringToFront() }
    func overlayViewDidRequestOCR() { requestOCR() }
    func overlayViewDidRequestQuickSave() { copyCurrentImage() }
    func overlayViewDidRequestUpload() { uploadCurrentImage() }
    func overlayViewDidRequestShare(anchorView: NSView?) { shareCurrentImage(anchorView: anchorView) }
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() { finishEditing() }
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidChangeWindowSnapState() {}
    func overlayViewDidRequestAddCapture() {}

    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground() {}
}

// MARK: - Pin Panel

private class PinPanel: NSPanel {
    weak var pinController: PinWindowController?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.keyCode == 12 {
            pinController?.close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Pin Content View

private class PinView: NSView {

    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onToggleShadow: (() -> Void)?
    var onToggleMarkdownRendering: (() -> Void)?
    var onZoom: ((CGFloat, NSPoint) -> Void)?
    var onResetZoom: (() -> Void)?
    var canToggleMarkdownRendering = false
    var markdownRenderingEnabled = false
    var showsBorder: Bool = true {
        didSet { needsDisplay = true }
    }

    private let image: NSImage
    private var closeButton: NSButton?
    private var editButton: NSButton?
    private var zoomLabel: NSTextField?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    var zoomPercent: Int = 100 {
        didSet {
            zoomLabel?.stringValue = "\(zoomPercent)%"
            zoomLabel?.sizeToFit()
            needsLayout = true
        }
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        setupButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeOverlayButton(symbol: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        btn.bezelStyle = .circular
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 12
        btn.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        btn.image = img
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        btn.isHidden = true
        return btn
    }

    private func setupButtons() {
        let edit = makeOverlayButton(symbol: "pencil", action: #selector(editClicked))
        addSubview(edit)
        editButton = edit

        let close = makeOverlayButton(symbol: "xmark", action: #selector(closeClicked))
        addSubview(close)
        closeButton = close

        let label = VerticallyCenteredTextField(labelWithString: "100%")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 12
        label.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        label.alignment = .center
        label.isHidden = true
        addSubview(label)
        zoomLabel = label
    }

    @objc private func closeClicked() {
        onClose?()
    }

    @objc private func editClicked() {
        onEdit?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        editButton?.isHidden = false
        closeButton?.isHidden = false
        zoomLabel?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        editButton?.isHidden = true
        closeButton?.isHidden = true
        zoomLabel?.isHidden = true
    }

    override func layout() {
        super.layout()
        let btnSize: CGFloat = 24
        let btnY = bounds.maxY - 30
        closeButton?.frame = NSRect(x: bounds.maxX - 30, y: btnY, width: btnSize, height: btnSize)
        editButton?.frame = NSRect(x: bounds.maxX - 58, y: btnY, width: btnSize, height: btnSize)
        if let label = zoomLabel {
            let labelW = max(label.intrinsicContentSize.width + 14, 42)
            label.frame = NSRect(
                x: bounds.maxX - 58 - labelW - 6,
                y: btnY,
                width: labelW,
                height: btnSize
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)

        guard showsBorder else { return }
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Copy to Clipboard"), action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: L("Save As..."), action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L("Edit"), action: #selector(editClicked), keyEquivalent: "")
        if canToggleMarkdownRendering {
            let markdownItem = menu.addItem(withTitle: L("Render Markdown"), action: #selector(toggleMarkdownRendering), keyEquivalent: "")
            markdownItem.state = markdownRenderingEnabled ? .on : .off
        }
        let shadowItem = menu.addItem(withTitle: L("Shadow"), action: #selector(toggleShadow), keyEquivalent: "")
        shadowItem.state = window?.hasShadow == true ? .on : .off
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L("Close"), action: #selector(closeClicked), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func copyImage() {
        onCopy?()
    }

    @objc private func saveImage() {
        onSave?()
    }

    @objc private func toggleShadow() {
        onToggleShadow?()
    }

    @objc private func toggleMarkdownRendering() {
        onToggleMarkdownRendering?()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            onClose?()
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        if let label = zoomLabel, !label.isHidden, label.frame.contains(loc) {
            onResetZoom?()
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.03
        let factor: CGFloat = 1.0 + delta * sensitivity
        let loc = convert(event.locationInWindow, from: nil)
        onZoom?(factor, loc)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        let loc = convert(event.locationInWindow, from: nil)
        onZoom?(factor, loc)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            onEdit?()
        case 53:
            onClose?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Inline Pin Editor

private class PinEditorView: OverlayView {
    enum ToolbarPlacement {
        case belowImage
        case aboveImage
    }

    var imageViewRect: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    var toolbarPlacement: ToolbarPlacement = .belowImage
    var onRequestChromeRelayout: (() -> Void)?
    private let optionsRowHeight: CGFloat = 34
    private let toolbarPreviewGap: CGFloat = 8

    override var isEditorMode: Bool { true }
    override var shouldShowRightToolbar: Bool { false }
    override func shouldAllowNewSelection() -> Bool { false }
    override func shouldAllowSelectionResize() -> Bool { false }
    override func shouldAllowDetach() -> Bool { false }
    override func requestEditorChromeRelayout() {
        onRequestChromeRelayout?()
    }

    override func drawEditorBackground(context: NSGraphicsContext) {
        context.cgContext.clear(bounds)
        if let image = screenshotImage {
            image.draw(in: imageViewRect, from: .zero, operation: .copy, fraction: 1.0)
        }
    }

    override func adjustPointForEditor(_ p: NSPoint) -> NSPoint {
        guard imageViewRect.width > 0, imageViewRect.height > 0,
              selectionRect.width > 0, selectionRect.height > 0 else { return p }
        return NSPoint(
            x: selectionRect.minX + (p.x - imageViewRect.minX) * selectionRect.width / imageViewRect.width,
            y: selectionRect.minY + (p.y - imageViewRect.minY) * selectionRect.height / imageViewRect.height
        )
    }

    override func canvasToView(_ p: NSPoint) -> NSPoint {
        guard selectionRect.width > 0, selectionRect.height > 0,
              imageViewRect.width > 0, imageViewRect.height > 0 else { return p }
        return NSPoint(
            x: imageViewRect.minX + (p.x - selectionRect.minX) * imageViewRect.width / selectionRect.width,
            y: imageViewRect.minY + (p.y - selectionRect.minY) * imageViewRect.height / selectionRect.height
        )
    }

    override func applyEditorTransform(to context: NSGraphicsContext) {
        guard selectionRect.width > 0, selectionRect.height > 0,
              imageViewRect.width > 0, imageViewRect.height > 0 else { return }
        context.cgContext.translateBy(x: imageViewRect.minX, y: imageViewRect.minY)
        context.cgContext.scaleBy(
            x: imageViewRect.width / selectionRect.width,
            y: imageViewRect.height / selectionRect.height
        )
        context.cgContext.translateBy(x: -selectionRect.minX, y: -selectionRect.minY)
    }

    override var captureDrawRect: NSRect { selectionRect }

    func renderCommittedPinImage() -> NSImage? {
        guard let base = captureSelectedRegion() else { return nil }
        guard beautifyEnabled else { return base }
        return BeautifyRenderer.render(image: base, config: beautifyConfig)
    }

    func committedPinScreenRect(windowFrame: NSRect) -> NSRect? {
        let rect = beautifyEnabled ? previewViewRect : imageViewRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return NSRect(
            x: windowFrame.minX + rect.minX,
            y: windowFrame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    func editorChromeContentWidth(fallback: CGFloat) -> CGFloat {
        guard showToolbars else { return fallback }
        let bottomWidth = bottomBarRect.width > 0 ? bottomBarRect.width : fallback
        let localRow = subviews.compactMap { $0 as? ToolOptionsRowView }.first
        let parentRow = chromeParentView?.subviews.compactMap { $0 as? ToolOptionsRowView }.first
        let rowWidth = (localRow ?? parentRow)?.contentWidth ?? 0
        return max(fallback, bottomWidth, rowWidth)
    }

    private var previewViewRect: NSRect {
        let sx = imageViewRect.width / max(selectionRect.width, 1)
        let sy = imageViewRect.height / max(selectionRect.height, 1)
        let margins = PinEditorBeautifyMargins
            .canvas(config: beautifyConfig, enabled: beautifyEnabled)
            .scaled(x: sx, y: sy)
        return NSRect(
            x: imageViewRect.minX - margins.left,
            y: imageViewRect.minY - margins.bottom,
            width: imageViewRect.width + margins.left + margins.right,
            height: imageViewRect.height + margins.bottom + margins.top
        )
    }

    override func positionEditorToolbarStrips(
        bottomStrip: ToolbarStripView,
        rightStrip: ToolbarStripView,
        bottomSize: NSSize,
        rightSize: NSSize,
        containerBounds: NSRect
    ) {
        let anchorRect = previewViewRect
        let x = max(4, min(anchorRect.midX - bottomSize.width / 2, containerBounds.maxX - bottomSize.width - 4))
        let y: CGFloat
        switch toolbarPlacement {
        case .belowImage:
            y = max(4, anchorRect.minY - toolbarPreviewGap - optionsRowHeight - 2 - bottomSize.height)
        case .aboveImage:
            y = min(containerBounds.maxY - bottomSize.height - 4, anchorRect.maxY + toolbarPreviewGap + optionsRowHeight + 2)
        }
        bottomStrip.frame.origin = NSPoint(x: x, y: y)
        bottomStrip.autoresizingMask = [.minXMargin, .maxXMargin]
        rightStrip.frame.origin = NSPoint(x: containerBounds.maxX - rightSize.width - 20, y: containerBounds.maxY - rightSize.height - 20)
        rightStrip.autoresizingMask = [.minXMargin, .minYMargin]
    }

    override func positionEditorOptionsRow(
        _ row: ToolOptionsRowView,
        rowWidth: CGFloat,
        bottomBarRect: NSRect,
        containerBounds: NSRect
    ) {
        let anchorRect = previewViewRect
        let rowX = max(4, min(anchorRect.midX - rowWidth / 2, containerBounds.maxX - rowWidth - 4))
        let y: CGFloat
        switch toolbarPlacement {
        case .belowImage:
            y = max(4, bottomBarRect.maxY + 2)
        case .aboveImage:
            y = min(anchorRect.maxY + toolbarPreviewGap, containerBounds.maxY - row.frame.height - 4)
        }
        row.frame.origin = NSPoint(x: rowX, y: y)
        row.autoresizingMask = [.minXMargin, .maxXMargin]
    }

    override func keyDown(with event: NSEvent) {
        if let textView = textEditView {
            if window?.firstResponder !== textView {
                window?.makeFirstResponder(textView)
            }
            textView.keyDown(with: event)
            return
        }
        if event.keyCode == 49 {
            overlayDelegate?.overlayViewDidCancel()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Vertically centered NSTextField

private class VerticallyCenteredCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        let y = max(0, (rect.height - textSize.height) / 2)
        return NSRect(x: rect.origin.x, y: rect.origin.y + y, width: rect.width, height: textSize.height)
    }
}

private class VerticallyCenteredTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { VerticallyCenteredCell.self }
        set {}
    }
}
