import Cocoa
import CryptoKit

enum ImageIdentity {
    static func dataIdentity(_ data: Data, prefix: String) -> String {
        "\(prefix):\(sha256(data))"
    }

    static func fileIdentity(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let payload = "\(url.standardizedFileURL.path)|\(size)|\(modified)"
        return dataIdentity(Data(payload.utf8), prefix: "clipboard-file")
    }

    static func imageIdentity(for image: NSImage) -> String {
        guard let cgImage = ImageEncoder.cgImage(for: image, downscale: false),
              let data = pixelData(for: cgImage) else {
            if let tiff = image.tiffRepresentation {
                return dataIdentity(tiff, prefix: "image-tiff")
            }
            return "image:\(image.size.width)x\(image.size.height)"
        }

        var bytes = Data()
        bytes.appendString("v1")
        bytes.appendString("rgba8")
        bytes.appendString("\(cgImage.width)x\(cgImage.height)")
        if let colorSpaceName = cgImage.colorSpace?.name {
            bytes.appendString(colorSpaceName as String)
        }
        bytes.append(data)
        return dataIdentity(bytes, prefix: "image-pixels")
    }

    private static func pixelData(for image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let ok = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    private static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
        append(0)
    }
}
