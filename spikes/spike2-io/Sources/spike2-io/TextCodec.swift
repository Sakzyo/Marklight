import Foundation

/// How a file's bytes map to editable text.
enum FileEncoding: String {
    case utf8, utf16LE, utf16BE
    /// UTF-8 where each invalid byte is carried as a private-use scalar
    /// (U+10FF00 + byte), so the text is editable and unknown bytes round-trip.
    case utf8Escaped
    /// Couldn't decode losslessly: keep raw bytes, open read-only.
    case raw
}

struct DecodedFile {
    var text: String
    let encoding: FileEncoding
    let hasBOM: Bool
    let raw: Data
}

enum TextCodec {
    static let escapeBase: UInt32 = 0x10FF00

    static func decode(_ data: Data) -> DecodedFile {
        let bytes = [UInt8](data)
        // 1. BOM sniffing.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = Array(bytes[3...])
            if let text = strictUTF8(body) {
                return DecodedFile(text: text, encoding: .utf8, hasBOM: true, raw: data)
            }
            if let text = escapedUTF8(body) {
                return DecodedFile(text: text, encoding: .utf8Escaped, hasBOM: true, raw: data)
            }
        }
        if bytes.starts(with: [0xFF, 0xFE]), let text = utf16(Array(bytes[2...]), littleEndian: true) {
            return DecodedFile(text: text, encoding: .utf16LE, hasBOM: true, raw: data)
        }
        if bytes.starts(with: [0xFE, 0xFF]), let text = utf16(Array(bytes[2...]), littleEndian: false) {
            return DecodedFile(text: text, encoding: .utf16BE, hasBOM: true, raw: data)
        }
        // 2. BOM-less UTF-16: NULs at regular positions. NUL is valid UTF-8, so
        //    this has to run before the UTF-8 check.
        if let le = looksLikeUTF16(bytes) {
            if let text = utf16(bytes, littleEndian: le) {
                return DecodedFile(text: text, encoding: le ? .utf16LE : .utf16BE, hasBOM: false, raw: data)
            }
        }
        // 3. UTF-8, strict then escaped.
        if let text = strictUTF8(bytes) {
            return DecodedFile(text: text, encoding: .utf8, hasBOM: false, raw: data)
        }
        if let text = escapedUTF8(bytes) {
            return DecodedFile(text: text, encoding: .utf8Escaped, hasBOM: false, raw: data)
        }
        return DecodedFile(text: "", encoding: .raw, hasBOM: false, raw: data)
    }

    static func encode(_ file: DecodedFile) -> Data {
        var out: [UInt8] = []
        switch file.encoding {
        case .raw:
            return file.raw
        case .utf8:
            if file.hasBOM { out += [0xEF, 0xBB, 0xBF] }
            out += Array(file.text.utf8)
        case .utf8Escaped:
            if file.hasBOM { out += [0xEF, 0xBB, 0xBF] }
            for scalar in file.text.unicodeScalars {
                if scalar.value >= escapeBase + 0x80, scalar.value <= escapeBase + 0xFF {
                    out.append(UInt8(scalar.value - escapeBase))
                } else {
                    out += Array(String(scalar).utf8)
                }
            }
        case .utf16LE, .utf16BE:
            let le = file.encoding == .utf16LE
            if file.hasBOM { out += le ? [0xFF, 0xFE] : [0xFE, 0xFF] }
            for unit in file.text.utf16 {
                let lo = UInt8(unit & 0xFF), hi = UInt8(unit >> 8)
                out += le ? [lo, hi] : [hi, lo]
            }
        }
        return Data(out)
    }

    // MARK: - Decoders

    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded): scalars.append(Unicode.UTF8.decode(encoded))
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    /// Lossless UTF-8 decode: invalid bytes become U+10FF80...U+10FFFF.
    /// Returns nil if the file already contains scalars from that range,
    /// since they couldn't be told apart from escapes on save.
    static func escapedUTF8(_ bytes: [UInt8]) -> String? {
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        var offset = 0
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded):
                let scalar = Unicode.UTF8.decode(encoded)
                if scalar.value >= escapeBase + 0x80, scalar.value <= escapeBase + 0xFF { return nil }
                scalars.append(scalar)
                offset += encoded.count
            case .emptyInput:
                return String(scalars)
            case .error(let length):
                for byte in bytes[offset..<offset + length] {
                    scalars.append(Unicode.Scalar(escapeBase + UInt32(byte))!)
                }
                offset += length
            }
        }
    }

    static func utf16(_ bytes: [UInt8], littleEndian: Bool) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        let units: [UInt16] = stride(from: 0, to: bytes.count, by: 2).map {
            littleEndian ? UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
                         : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
        var parser = Unicode.UTF16.ForwardParser()
        var iterator = units.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded): scalars.append(Unicode.UTF16.decode(encoded))
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    /// Returns true for LE, false for BE, nil if not UTF-16-looking.
    static func looksLikeUTF16(_ bytes: [UInt8]) -> Bool? {
        guard bytes.count >= 2, bytes.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, b) in bytes.enumerated() where b == 0 { if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
        let half = bytes.count / 2
        if oddZeros * 10 >= half * 3, evenZeros * 10 < half { return true }
        if evenZeros * 10 >= half * 3, oddZeros * 10 < half { return false }
        return nil
    }
}

/// Text equality that ignores Swift's canonical equivalence: `==` on String
/// treats "é" (U+00E9) and "e\u{301}" as equal, which would hide real edits.
func exactlyEqual(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}
