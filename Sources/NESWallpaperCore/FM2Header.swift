import Foundation

/// Parsed header of an FM2 (FCEUX) movie file.
///
/// FM2 is a text format: header lines of the form `key value` (first space
/// separates key from value), followed by input records — lines starting
/// with `|`. The header ends at the first input record; the movie's frame
/// count is the number of input records.
public struct FM2Header {
    /// ROM name as recorded by the emulator (usually without extension).
    public var romFilename: String = ""
    /// MD5 of the ROM file bytes after the 16-byte iNES header.
    /// 16 bytes, or empty if the header had no parseable `romChecksum`.
    public var romChecksum: Data = Data()
    /// Number of input records (`|` lines) in the movie.
    public var frameCount: Int = 0
    public var palFlag: Bool = false
    public var newPPU: Bool = false
    public var port0: Int = 0
    public var port1: Int = 0

    public init() {}

    public static func parse(fileURL: URL) throws -> FM2Header {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return parse(data: data)
    }

    /// Single pass over the raw bytes: header lines are decoded and parsed,
    /// input records are only counted (movies can have 100k+ of them).
    public static func parse(data: Data) -> FM2Header {
        var header = FM2Header()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var inHeader = true
            var lineStart = 0
            for index in 0...bytes.count {
                let atEnd = index == bytes.count
                guard atEnd || bytes[index] == 0x0A else { continue } // '\n'
                var lineEnd = index
                if lineEnd > lineStart, bytes[lineEnd - 1] == 0x0D { // '\r'
                    lineEnd -= 1
                }
                if lineEnd > lineStart {
                    if bytes[lineStart] == 0x7C { // '|'
                        header.frameCount += 1
                        inHeader = false
                    } else if inHeader {
                        let line = String(
                            decoding: bytes[lineStart..<lineEnd], as: UTF8.self)
                        header.applyHeaderLine(line)
                    }
                }
                lineStart = index + 1
            }
        }
        return header
    }

    private mutating func applyHeaderLine(_ line: String) {
        let key: Substring
        let value: Substring
        if let space = line.firstIndex(of: " ") {
            key = line[..<space]
            value = line[line.index(after: space)...]
        } else {
            key = line[...]
            value = ""
        }
        switch key {
        case "romFilename": romFilename = String(value)
        case "romChecksum": romChecksum = Self.parseChecksum(value)
        case "palFlag": palFlag = value == "1"
        case "NewPPU": newPPU = value == "1"
        case "port0": port0 = Int(value) ?? 0
        case "port1": port1 = Int(value) ?? 0
        default: break
        }
    }

    /// FCEUX writes `base64:<b64 of the 16 MD5 bytes>`; some files carry a
    /// plain hex form instead. Returns empty Data if neither parses to
    /// exactly 16 bytes.
    private static func parseChecksum(_ value: Substring) -> Data {
        if value.hasPrefix("base64:") {
            let encoded = String(value.dropFirst("base64:".count))
            guard let decoded = Data(base64Encoded: encoded), decoded.count == 16 else {
                return Data()
            }
            return decoded
        }
        var hex = value
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = hex.dropFirst(2) }
        guard hex.count == 32 else { return Data() }
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var digits = hex[...]
        while !digits.isEmpty {
            guard let byte = UInt8(digits.prefix(2), radix: 16) else { return Data() }
            bytes.append(byte)
            digits = digits.dropFirst(2)
        }
        return Data(bytes)
    }
}
