import Cocoa
import UniformTypeIdentifiers
import ImageIO
import WebP

/// Shared image encoding with user-configurable format, quality, and resolution.
enum ImageEncoder {

    enum Format: String {
        case png = "png"
        case jpeg = "jpeg"
        case heic = "heic"
        case webp = "webp"
    }

    static var format: Format {
        if let raw = UserDefaults.standard.string(forKey: "imageFormat"),
           let fmt = Format(rawValue: raw) {
            return fmt
        }
        return .png
    }

    /// Lossy quality 0.0–1.0 (used for JPEG, HEIC, and WebP)
    static var quality: CGFloat {
        if let q = UserDefaults.standard.object(forKey: "imageQuality") as? Double {
            return CGFloat(max(0.1, min(1.0, q)))
        }
        return 0.85
    }

    /// Whether to downscale Retina (2x) screenshots to standard (1x) resolution.
    static var downscaleRetina: Bool {
        UserDefaults.standard.bool(forKey: "downscaleRetina")
    }

    static var fileExtension: String {
        switch format {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    static var utType: UTType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .webp: return .webP
        }
    }

    // MARK: - Shared image creation

    /// Create a CGImage from an NSImage, optionally downscaling from Retina.
    /// Uses cgImage(forProposedRect:) instead of tiffRepresentation to preserve
    /// exact pixel data regardless of the current display's backing scale factor.
    static func cgImage(for image: NSImage, downscale: Bool = downscaleRetina) -> CGImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Fallback for images without a CGImage backing (e.g. PDF/EPS vectors)
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
            return bitmap.cgImage
        }

        if downscale {
            let logicalW = Int(image.size.width)
            let logicalH = Int(image.size.height)
            let pixelW = cgImage.width
            let pixelH = cgImage.height

            if pixelW > logicalW && pixelH > logicalH {
                let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                guard let ctx = CGContext(
                    data: nil,
                    width: logicalW, height: logicalH,
                    bitsPerComponent: 8,
                    bytesPerRow: logicalW * 4,
                    space: cs,
                    bitmapInfo: bitmapInfo
                ) else { return cgImage }
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: logicalW, height: logicalH))
                guard let downscaled = ctx.makeImage() else { return cgImage }
                return downscaled
            }
        }

        return cgImage
    }

    // MARK: - Encoding

    /// Encode an NSImage to Data in the configured format.
    static func encode(_ image: NSImage) -> Data? {
        guard let cgImage = cgImage(for: image) else { return nil }

        switch format {
        case .png:
            return encodePNG(cgImage: cgImage)
        case .jpeg:
            return encodeJPEG(cgImage: cgImage, quality: quality)
        case .heic:
            return encodeHEIC(cgImage: cgImage, quality: quality)
        case .webp:
            return encodeWebP(cgImage: cgImage, quality: quality)
        }
    }

    /// Encode PNG with native color profile embedded.
    private static func encodePNG(cgImage: CGImage) -> Data? {
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.png", lossyQuality: nil)
    }

    /// Stable PNG bytes for features that need image identity independent of
    /// the user's configured output format.
    static func pngData(for image: NSImage) -> Data? {
        guard let cgImage = cgImage(for: image, downscale: false) else { return nil }
        return encodePNG(cgImage: cgImage)
    }

    /// Encode JPEG with native color profile embedded.
    private static func encodeJPEG(cgImage: CGImage, quality: CGFloat) -> Data? {
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.jpeg", lossyQuality: quality)
    }

    /// Encode HEIC via CGImageDestination (NSBitmapImageRep doesn't support HEIC).
    private static func encodeHEIC(cgImage: CGImage, quality: CGFloat) -> Data? {
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.heic", lossyQuality: quality)
    }

    /// Encode WebP via Swift-WebP (libwebp).
    /// Uses the CGImage RGBA path directly — the library's NSImage path has a bug
    /// (assumes RGB stride and logical size instead of pixel size).
    private static func encodeWebP(cgImage: CGImage, quality: CGFloat) -> Data? {
        let w = cgImage.width
        let h = cgImage.height
        // Re-render into a known premultipliedLast RGBA context (preserving source color space)
        let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rgbaImage = ctx.makeImage() else { return nil }

        let encoder = WebPEncoder()
        let config = WebPEncoderConfig.preset(.picture, quality: Float(quality * 100))
        return try? encoder.encode(RGBA: rgbaImage, config: config)
    }

    /// Generic CGImageDestination encoder — embeds the source color profile.
    /// The CGImage already carries its display's ICC profile (e.g. Display P3).
    /// CGImageDestination embeds it automatically — no pixel conversion needed.
    private static func encodeWithCGImageDestination(cgImage: CGImage, type: String, lossyQuality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }

        var properties: [String: Any] = [:]
        if let q = lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = q
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Clipboard

    /// Dedicated subfolder for the clipboard-paste temp file. Isolated so
    /// we can sweep it without worrying about matching user-configured
    /// filename templates. Created lazily by `clipboardTmpDirectory`.
    private static let clipboardTmpSubfolder = "macshot-clipboard"

    /// Path to the clipboard temp subfolder. Always exists after first
    /// access — created on demand with `createDirectory(withIntermediateDirectories: true)`.
    static let clipboardTmpDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(clipboardTmpSubfolder)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    /// Copy image to pasteboard as PNG.
    /// Explicitly sets PNG data so receiving apps (browsers, editors) get
    /// a lossless PNG instead of the TIFF that NSImage.writeObjects provides.
    /// Also writes a temp file so Finder paste (Cmd+V in a folder) works
    /// and the pasted file has a nice date-stamped filename instead of
    /// something like `macshot-clipboard.png`.
    ///
    /// Disk hygiene:
    ///   - Each copy gets its own temp file. Old pasteboards may still point
    ///     at earlier files, so deleting the previous file on the next copy
    ///     breaks delayed Finder/app pastes.
    ///   - Launch cleanup sweeps this dedicated folder by age.
    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = cgImage(for: image),
                  let pngData = encodePNG(cgImage: cgImage) else { return }

            // Compute the new file path with a date-stamped filename so
            // Finder pastes land as a nicely named file. A counter suffix
            // guards the very unlikely case where two copies in the same
            // second produce the same name.
            let dir = clipboardTmpDirectory
            var candidate = dir.appendingPathComponent(FilenameFormatter.defaultImageFilename())
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                let base = FilenameFormatter.defaultImageFilename()
                    .replacingOccurrences(of: ".\(ImageEncoder.fileExtension)", with: "")
                candidate = dir.appendingPathComponent("\(base) (\(counter)).\(ImageEncoder.fileExtension)")
                counter += 1
                if counter > 1000 { break }  // sanity
            }
            let newURL = candidate

            // Atomic write avoids partial reads by in-flight Finder pastes.
            let writeOK = (try? pngData.write(to: newURL, options: .atomic)) != nil
            let fileURL = writeOK ? newURL : nil
            DispatchQueue.main.async {
                var types: [NSPasteboard.PasteboardType] = [.png]
                if fileURL != nil { types.append(.fileURL) }
                pasteboard.declareTypes(types, owner: nil)
                pasteboard.setData(pngData, forType: .png)
                if let url = fileURL {
                    pasteboard.setString(url.absoluteString, forType: .fileURL)
                }
            }
        }
    }
}
