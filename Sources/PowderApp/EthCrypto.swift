import Foundation
import P256K

// MARK: - Hex

extension Data {
    /// Lowercase hex without a prefix.
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// Parses hex with or without `0x`; `nil` when it is not valid hex of even length.
    init?(hex string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text = text.dropFirst(2) }
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

// MARK: - Keccak-256

/// Ethereum's hash (original Keccak padding, not NIST SHA-3).
enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]
    private static let rotations = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let lanes = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]
    private static let rate = 136

    static func hash(_ data: Data) -> Data {
        var input = [UInt8](data)
        input.append(0x01)
        while !input.count.isMultiple(of: rate) { input.append(0) }
        input[input.count - 1] |= 0x80

        var state = [UInt64](repeating: 0, count: 25)
        for block in stride(from: 0, to: input.count, by: rate) {
            for lane in 0..<(rate / 8) {
                var word: UInt64 = 0
                for byte in 0..<8 { word |= UInt64(input[block + lane * 8 + byte]) << (8 * UInt64(byte)) }
                state[lane] ^= word
            }
            permute(&state)
        }

        var output = Data(capacity: 32)
        for lane in 0..<4 {
            for byte in 0..<8 { output.append(UInt8(truncatingIfNeeded: state[lane] >> (8 * UInt64(byte)))) }
        }
        return output
    }

    private static func rotate(_ value: UInt64, _ count: Int) -> UInt64 {
        (value << UInt64(count)) | (value >> UInt64(64 - count))
    }

    private static func permute(_ state: inout [UInt64]) {
        var column = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            for x in 0..<5 { column[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] }
            for x in 0..<5 {
                let mix = column[(x + 4) % 5] ^ rotate(column[(x + 1) % 5], 1)
                for y in stride(from: 0, to: 25, by: 5) { state[y + x] ^= mix }
            }
            var carried = state[1]
            for step in 0..<24 {
                let lane = lanes[step]
                let next = state[lane]
                state[lane] = rotate(carried, rotations[step])
                carried = next
            }
            for y in stride(from: 0, to: 25, by: 5) {
                for x in 0..<5 { column[x] = state[y + x] }
                for x in 0..<5 { state[y + x] ^= ~column[(x + 1) % 5] & column[(x + 2) % 5] }
            }
            state[0] ^= roundConstants[round]
        }
    }
}

// MARK: - Keys

struct EthSignature: Equatable, Sendable {
    /// 32-byte values as `0x`-prefixed hex.
    let r: String
    let s: String
    /// 27 or 28.
    let v: Int
}

enum EthKeyError: LocalizedError {
    case invalidPrivateKey

    var errorDescription: String? {
        "That is not a valid private key. It should be 64 hexadecimal characters, with or without 0x."
    }
}

/// secp256k1 operations for Ethereum-style accounts, on Bitcoin Core's libsecp256k1.
enum EthKey {
    /// A new random 32-byte private key.
    static func generate() throws -> Data {
        try P256K.Recovery.PrivateKey().dataRepresentation
    }

    /// Accepts 64 hex characters with or without `0x`.
    static func parse(_ text: String) throws -> Data {
        guard let data = Data(hex: text), data.count == 32, (try? P256K.Recovery.PrivateKey(dataRepresentation: data)) != nil else {
            throw EthKeyError.invalidPrivateKey
        }
        return data
    }

    /// The account address: the last 20 bytes of the hash of the public key, lowercase with `0x`.
    static func address(of privateKey: Data) throws -> String {
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        let publicKey = key.publicKey.dataRepresentation
        guard publicKey.count == 65 else { throw EthKeyError.invalidPrivateKey }
        return "0x" + Keccak256.hash(publicKey.dropFirst()).suffix(20).hex
    }

    /// Signs a 32-byte digest, returning the recoverable signature Ethereum expects.
    static func sign(digest: Data, with privateKey: Data) throws -> EthSignature {
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey)
        let compact = try key.signature(for: HashDigest([UInt8](digest))).compactRepresentation
        return EthSignature(
            r: "0x" + compact.signature.prefix(32).hex,
            s: "0x" + compact.signature.suffix(32).hex,
            v: 27 + Int(compact.recoveryId)
        )
    }
}
