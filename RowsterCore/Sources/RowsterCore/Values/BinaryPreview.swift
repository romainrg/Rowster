import Foundation

/// How to show a binary value: recognise common image formats, or print bytes as a hex dump.
public enum BinaryPreview {
    /// The image format of the data, from its first bytes; `nil` when it is not a known image.
    public static func imageType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8]) -> Bool { bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "PNG" }
        if starts([0xFF, 0xD8, 0xFF]) { return "JPEG" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "GIF" }
        if starts([0x42, 0x4D]) { return "BMP" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "TIFF" }
        if bytes.count >= 12, Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "WebP"
        }
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "avif"].contains(brand) { return brand == "avif" ? "AVIF" : "HEIC" }
        }
        return nil
    }

    /// A classic hex dump: offset, sixteen bytes, their printable ASCII. At most `limit` bytes are printed.
    public static func hexDump(_ data: Data, limit: Int = 4096) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = ""
            for (position, byte) in chunk.enumerated() {
                hex += String(format: "%02x ", byte)
                if position == 7 { hex += " " }
            }
            let ascii = chunk.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." }
            lines.append(String(format: "%08x  ", offset) + hex.padding(toLength: 50, withPad: " ", startingAt: 0) + "|" + String(ascii) + "|")
            offset += 16
        }
        if data.count > limit { lines.append("…") }
        return lines.joined(separator: "\n")
    }
}
