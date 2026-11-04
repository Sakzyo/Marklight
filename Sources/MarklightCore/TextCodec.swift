import Foundation

/// How a file's bytes map to editable text.
public enum TextEncoding: Sendable, Equatable {
    case utf8
    case utf16LE
    case utf16BE
    /// UTF-8 in which each invalid byte is carried as a private-use scalar, so the
    /// text stays editable and unknown bytes survive edits elsewhere.
    case utf8Escaped
    /// Couldn't be decoded without loss. The file opens read-only.
    case raw
}

/// What has to be remembered to write a file back byte for byte.
public struct FileFormat: Sendable, Equatable {
    public var encoding: TextEncoding
    public var hasBOM: Bool

    public init(encoding: TextEncoding = .utf8, hasBOM: Bool = false) {
        self.encoding = encoding
        self.hasBOM = hasBOM
    }

    public static let newDocument = FileFormat()
}

public enum TextCodec {
    /// Invalid byte `b` is carried as U+10FF00 + `b`, so U+10FF80...U+10FFFF.
    static let escapeBase: UInt32 = 0x10FF00

    public static func isEscapedByte(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= escapeBase + 0x80 && scalar.value <= escapeBase + 0xFF
    }

    public static func decode(_ data: Data) -> (units: [UInt16], format: FileFormat) {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = Array(bytes[3...])
            if let text = strictUTF8(body) { return (text, FileFormat(encoding: .utf8, hasBOM: true)) }
            if let text = escapedUTF8(body) { return (text, FileFormat(encoding: .utf8Escaped, hasBOM: true)) }
        }
        if bytes.starts(with: [0xFF, 0xFE]), let text = utf16(Array(bytes[2...]), littleEndian: true) {
            return (text, FileFormat(encoding: .utf16LE, hasBOM: true))
        }
        if bytes.starts(with: [0xFE, 0xFF]), let text = utf16(Array(bytes[2...]), littleEndian: false) {
            return (text, FileFormat(encoding: .utf16BE, hasBOM: true))
        }
        // NUL is valid UTF-8, so BOM-less UTF-16 has to be ruled out first.
        if let littleEndian = looksLikeUTF16(bytes), let text = utf16(bytes, littleEndian: littleEndian) {
            return (text, FileFormat(encoding: littleEndian ? .utf16LE : .utf16BE))
        }
        if let text = strictUTF8(bytes) { return (text, FileFormat(encoding: .utf8)) }
        if let text = escapedUTF8(bytes) { return (text, FileFormat(encoding: .utf8Escaped)) }
        return ([], FileFormat(encoding: .raw))
    }

    public static func encode(_ units: [UInt16], format: FileFormat) -> Data {
        var out = Data()
        out.reserveCapacity(units.count * 2)
        switch format.encoding {
        case .raw:
            preconditionFailure("raw files are written from their original bytes")
        case .utf8:
            if format.hasBOM { out.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            out.append(contentsOf: String(decoding: units, as: UTF16.self).utf8)
        case .utf8Escaped:
            if format.hasBOM { out.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
                if isEscapedByte(scalar) {
                    out.append(UInt8(scalar.value - escapeBase))
                } else {
                    out.append(contentsOf: UTF8.encode(scalar)!)
                }
            }
        case .utf16LE, .utf16BE:
            let little = format.encoding == .utf16LE
            if format.hasBOM { out.append(contentsOf: little ? [0xFF, 0xFE] : [0xFE, 0xFF]) }
            for unit in units {
                let lo = UInt8(unit & 0xFF), hi = UInt8(unit >> 8)
                out.append(contentsOf: little ? [lo, hi] : [hi, lo])
            }
        }
        return out
    }

    private static func strictUTF8(_ bytes: [UInt8]) -> [UInt16]? {
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = bytes.makeIterator()
        var out: [UInt16] = []
        out.reserveCapacity(bytes.count)
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded): out.append(contentsOf: UTF16.encode(Unicode.UTF8.decode(encoded))!)
            case .emptyInput: return out
            case .error: return nil
            }
        }
    }

    /// Returns nil if the file already contains scalars from the escape range,
    /// since they couldn't be told apart from escapes on save.
    private static func escapedUTF8(_ bytes: [UInt8]) -> [UInt16]? {
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = bytes.makeIterator()
        var out: [UInt16] = []
        var offset = 0
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded):
                let scalar = Unicode.UTF8.decode(encoded)
                if isEscapedByte(scalar) { return nil }
                out.append(contentsOf: UTF16.encode(scalar)!)
                offset += encoded.count
            case .emptyInput:
                return out
            case .error(let length):
                for byte in bytes[offset..<offset + length] {
                    out.append(contentsOf: UTF16.encode(Unicode.Scalar(escapeBase + UInt32(byte))!)!)
                }
                offset += length
            }
        }
    }

    private static func utf16(_ bytes: [UInt8], littleEndian: Bool) -> [UInt16]? {
        guard bytes.count % 2 == 0 else { return nil }
        let units: [UInt16] = stride(from: 0, to: bytes.count, by: 2).map {
            littleEndian ? UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
                         : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
        // Lone surrogates can't live in a Swift String, so they'd change on save.
        var parser = Unicode.UTF16.ForwardParser()
        var iterator = units.makeIterator()
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid: continue
            case .emptyInput: return units
            case .error: return nil
            }
        }
    }

    /// True for little-endian, false for big-endian, nil if it doesn't look like UTF-16.
    private static func looksLikeUTF16(_ bytes: [UInt8]) -> Bool? {
        guard bytes.count >= 2, bytes.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, byte) in bytes.enumerated() where byte == 0 {
            if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = bytes.count / 2
        if oddZeros * 10 >= half * 3, evenZeros * 10 < half { return true }
        if evenZeros * 10 >= half * 3, oddZeros * 10 < half { return false }
        return nil
    }
}
