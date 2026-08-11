import CryptoKit
import Foundation

/// Synthetic ROM/FM2 fixture builders shared across test cases.
enum Fixtures {
    /// Minimal fake ROM: 16-byte iNES header ("NES\x1a" magic) plus a few KB
    /// of deterministic payload derived from `seed`.
    static func makeROMData(seed: UInt8, payloadSize: Int = 4096) -> Data {
        var data = Data([0x4E, 0x45, 0x53, 0x1A]) // "NES\x1a"
        data.append(Data(repeating: 0, count: 12))
        data.append(Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0) &+ seed }))
        return data
    }

    /// MD5 of the bytes after the 16-byte iNES header — what FCEUX embeds
    /// as `romChecksum` in FM2 files.
    static func checksum(of romData: Data) -> Data {
        Data(Insecure.MD5.hash(data: romData.dropFirst(16)))
    }

    static func fm2Text(checksumLine: String?, frames: Int,
                        romFilename: String = "fixture") -> String {
        var text = """
        version 3
        emuVersion 20606
        palFlag 0
        romFilename \(romFilename)

        """
        if let checksumLine {
            text += "romChecksum \(checksumLine)\n"
        }
        text += "port0 1\nport1 1\nNewPPU 0\n"
        for _ in 0..<frames {
            text += "|0|........|........||\n"
        }
        return text
    }

    static func base64Line(_ checksum: Data) -> String {
        "base64:\(checksum.base64EncodedString())"
    }
}
