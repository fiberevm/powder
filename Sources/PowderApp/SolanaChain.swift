import CryptoKit
import Foundation
import os

// MARK: - Base58

/// Bitcoin-alphabet base58, as Solana writes addresses, keys and signatures.
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let values: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let zeros = bytes.prefix { $0 == 0 }.count
        var digits: [UInt8] = []
        for byte in bytes.dropFirst(zeros) {
            var carry = Int(byte)
            for index in digits.indices {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let text = Array(repeating: alphabet[0], count: zeros) + digits.reversed().map { alphabet[Int($0)] }
        return String(decoding: text, as: UTF8.self)
    }

    static func decode(_ string: String) -> Data? {
        let characters = Array(string.utf8)
        let zeros = characters.prefix { $0 == alphabet[0] }.count
        var bytes: [UInt8] = []
        for character in characters.dropFirst(zeros) {
            guard var carry = values[character] else { return nil }
            for index in bytes.indices {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }
        return Data(Array(repeating: 0, count: zeros) + bytes.reversed())
    }
}

// MARK: - Keys

enum SolanaError: LocalizedError, Equatable {
    case badKey
    case badTransaction(String)
    case tooLarge
    case rpc(String)
    case noRoute(String)
    case notLanded
    case failedOnChain(String)

    var errorDescription: String? {
        switch self {
        case .badKey: "That is not a Solana private key. Paste the base58 key from your wallet, or the JSON array from a keypair file."
        case let .badTransaction(reason): "The swap transaction could not be read (\(reason))."
        case .tooLarge: "The swap route is too large to fit in one transaction with the tip."
        case let .rpc(message): message
        case let .noRoute(message): "No swap route: \(message)"
        case .notLanded: "The transaction did not land before it expired. Nothing was spent."
        case let .failedOnChain(reason): "The transaction landed but failed (\(reason)). Only the network fee and tip were spent."
        }
    }
}

/// Ed25519 keys as Solana uses them. The stored secret is the 32-byte seed.
enum SolanaKey {
    static func generate() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    /// Accepts what wallets export: base58 of the 64-byte keypair (or the 32-byte seed), or a keypair file's JSON array.
    static func parse(_ text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes: Data?
        if trimmed.hasPrefix("[") {
            let numbers = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [Int]
            bytes = numbers.flatMap { $0.allSatisfy { (0...255).contains($0) } ? Data($0.map(UInt8.init)) : nil }
        } else {
            bytes = Base58.decode(trimmed)
        }
        guard let bytes, bytes.count == 64 || bytes.count == 32 else { throw SolanaError.badKey }
        let seed = Data(bytes.prefix(32))
        guard let publicKey = try? publicKey(of: seed) else { throw SolanaError.badKey }
        // A 64-byte keypair carries its public key; a mismatch means it is not a keypair at all.
        if bytes.count == 64, Data(bytes.suffix(32)) != publicKey { throw SolanaError.badKey }
        return seed
    }

    static func publicKey(of seed: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    static func address(of seed: Data) throws -> String {
        Base58.encode(try publicKey(of: seed))
    }

    /// The 64-byte keypair in base58, the form wallets import.
    static func export(_ seed: Data) throws -> String {
        Base58.encode(seed + (try publicKey(of: seed)))
    }

    static func sign(_ message: Data, seed: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
    }

    static func isAddress(_ text: String) -> Bool {
        (32...44).contains(text.count) && Base58.decode(text)?.count == 32
    }
}

// MARK: - Transactions

/// A Solana transaction (legacy or v0) taken apart so one instruction can be added and it can be signed.
/// Powder does not build swaps itself: the router returns one, and this adds the landing tip.
struct SolanaTransaction: Equatable {
    struct Instruction: Equatable {
        var program: UInt8
        var accounts: [UInt8]
        var data: Data
    }

    struct Lookup: Equatable {
        var table: Data
        var writable: [UInt8]
        var readonly: [UInt8]
    }

    static let maxSize = 1_232
    static let systemProgram = Data(repeating: 0, count: 32)

    var signatures: [Data]
    /// Nil for a legacy transaction, 0 for v0.
    var version: UInt8?
    var requiredSignatures: UInt8
    var readonlySigned: UInt8
    var readonlyUnsigned: UInt8
    var keys: [Data]
    var blockhash: Data
    var instructions: [Instruction]
    var lookups: [Lookup]

    init(_ data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        let count = try reader.compact()
        signatures = try (0..<count).map { _ in Data(try reader.take(64)) }
        let first = try reader.peek()
        if first & 0x80 != 0 {
            version = try reader.byte() & 0x7F
            guard version == 0 else { throw SolanaError.badTransaction("unknown version") }
        }
        requiredSignatures = try reader.byte()
        readonlySigned = try reader.byte()
        readonlyUnsigned = try reader.byte()
        keys = try (0..<(try reader.compact())).map { _ in Data(try reader.take(32)) }
        blockhash = Data(try reader.take(32))
        instructions = try (0..<(try reader.compact())).map { _ in
            let program = try reader.byte()
            let accounts = try reader.take(try reader.compact())
            let data = Data(try reader.take(try reader.compact()))
            return Instruction(program: program, accounts: accounts, data: data)
        }
        lookups = []
        if version != nil {
            lookups = try (0..<(try reader.compact())).map { _ in
                let table = Data(try reader.take(32))
                let writable = try reader.take(try reader.compact())
                let readonly = try reader.take(try reader.compact())
                return Lookup(table: table, writable: writable, readonly: readonly)
            }
        }
        guard reader.isAtEnd else { throw SolanaError.badTransaction("trailing bytes") }
        guard signatures.count == Int(requiredSignatures), keys.count >= signatures.count else {
            throw SolanaError.badTransaction("signature count")
        }
    }

    /// The bytes that get signed.
    var message: Data {
        var out = Data()
        if let version { out.append(0x80 | version) }
        out.append(contentsOf: [requiredSignatures, readonlySigned, readonlyUnsigned])
        out.append(Self.compact(keys.count))
        keys.forEach { out.append($0) }
        out.append(blockhash)
        out.append(Self.compact(instructions.count))
        for instruction in instructions {
            out.append(instruction.program)
            out.append(Self.compact(instruction.accounts.count))
            out.append(contentsOf: instruction.accounts)
            out.append(Self.compact(instruction.data.count))
            out.append(instruction.data)
        }
        if version != nil {
            out.append(Self.compact(lookups.count))
            for lookup in lookups {
                out.append(lookup.table)
                out.append(Self.compact(lookup.writable.count))
                out.append(contentsOf: lookup.writable)
                out.append(Self.compact(lookup.readonly.count))
                out.append(contentsOf: lookup.readonly)
            }
        }
        return out
    }

    var serialized: Data {
        var out = Self.compact(signatures.count)
        signatures.forEach { out.append($0) }
        out.append(message)
        return out
    }

    /// The transaction id: its first signature.
    var signature: String { Base58.encode(signatures.first ?? Data()) }

    /// Appends a SOL transfer from the fee payer, which is how a landing service is tipped.
    mutating func addTransfer(lamports: UInt64, to recipient: Data) throws {
        guard recipient.count == 32 else { throw SolanaError.badTransaction("recipient") }
        // The recipient first: adding it moves the read-only accounts, the system program among them.
        let target = try index(of: recipient, writable: true)
        let system = try index(of: Self.systemProgram, writable: false)
        var data = Data([2, 0, 0, 0])
        withUnsafeBytes(of: lamports.littleEndian) { data.append(contentsOf: $0) }
        instructions.append(Instruction(program: system, accounts: [0, target], data: data))
        guard serialized.count <= Self.maxSize else { throw SolanaError.tooLarge }
    }

    /// Where a key sits among the transaction's own (static) accounts, adding it when it is missing.
    /// Adding one shifts every account after it, so each instruction's references are moved along.
    private mutating func index(of key: Data, writable: Bool) throws -> UInt8 {
        let firstReadonlyUnsigned = keys.count - Int(readonlyUnsigned)
        if let existing = keys.firstIndex(of: key) {
            let isSigner = existing < Int(requiredSignatures)
            let isWritable = isSigner ? existing < Int(requiredSignatures) - Int(readonlySigned) : existing < firstReadonlyUnsigned
            guard isWritable || !writable else { throw SolanaError.badTransaction("recipient is read-only") }
            return UInt8(existing)
        }
        let total = keys.count + lookups.reduce(0) { $0 + $1.writable.count + $1.readonly.count }
        guard total < 255 else { throw SolanaError.tooLarge }
        // Writable accounts go just before the read-only ones; read-only accounts go last.
        let position = writable ? firstReadonlyUnsigned : keys.count
        keys.insert(key, at: position)
        if !writable { readonlyUnsigned += 1 }
        func moved(_ index: UInt8) -> UInt8 { Int(index) >= position ? index + 1 : index }
        for index in instructions.indices {
            instructions[index].program = moved(instructions[index].program)
            instructions[index].accounts = instructions[index].accounts.map(moved)
        }
        return UInt8(position)
    }

    /// Signs as the fee payer. The transaction must need no other signature.
    mutating func sign(seed: Data) throws {
        guard requiredSignatures == 1, keys.first == (try SolanaKey.publicKey(of: seed)) else {
            throw SolanaError.badTransaction("not this wallet's transaction")
        }
        signatures = [try SolanaKey.sign(message, seed: seed)]
    }

    static func compact(_ value: Int) -> Data {
        var remaining = value
        var out = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining > 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining > 0
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        func peek() throws -> UInt8 {
            guard offset < bytes.count else { throw SolanaError.badTransaction("too short") }
            return bytes[offset]
        }

        mutating func byte() throws -> UInt8 {
            let value = try peek()
            offset += 1
            return value
        }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw SolanaError.badTransaction("too short") }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func compact() throws -> Int {
            var value = 0
            for shift in stride(from: 0, to: 21, by: 7) {
                let byte = try byte()
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw SolanaError.badTransaction("length")
        }
    }
}

// MARK: - RPC

/// One token balance in a wallet.
struct SolanaHolding: Equatable, Sendable {
    let mint: String
    /// In whole tokens.
    let amount: Double
    /// In the token's smallest unit, exact, for selling all of it.
    let raw: UInt64
    let decimals: Int
}

struct SolanaBalances: Equatable, Sendable {
    var lamports: UInt64 = 0
    var holdings: [SolanaHolding] = []

    var sol: Double { Double(lamports) / 1e9 }

    func holding(_ mint: String) -> SolanaHolding? { holdings.first { $0.mint == mint } }
}

/// What the app asks a Solana node: balances, and whether a transaction landed.
enum SolanaRPC {
    static let defaultEndpoint = "https://api.mainnet-beta.solana.com"
    static let endpointKey = "solana.rpc"
    static let wrappedSOL = "So11111111111111111111111111111111111111112"
    private static let tokenPrograms = [
        "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
        "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
    ]

    static var endpoint: URL {
        let saved = UserDefaults.standard.string(forKey: endpointKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: saved.isEmpty ? defaultEndpoint : saved) ?? URL(string: defaultEndpoint)!
    }

    static func call(_ method: String, _ params: [Any], timeout: TimeInterval = 12) async throws -> Any {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw SolanaError.rpc("The Solana RPC is rate limiting this Mac. Set your own RPC address in Settings → Solana.")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SolanaError.rpc("The Solana RPC sent an unreadable reply.")
        }
        if let error = root["error"] as? [String: Any] {
            throw SolanaError.rpc(error["message"] as? String ?? "The Solana RPC refused the request.")
        }
        return root["result"] ?? NSNull()
    }

    static func balances(owner: String) async throws -> SolanaBalances {
        async let lamports = call("getBalance", [owner])
        async let classic = call("getTokenAccountsByOwner", [owner, ["programId": tokenPrograms[0]], ["encoding": "jsonParsed"]])
        async let extended = call("getTokenAccountsByOwner", [owner, ["programId": tokenPrograms[1]], ["encoding": "jsonParsed"]])
        var result = SolanaBalances()
        result.lamports = ((try await lamports as? [String: Any])?["value"] as? NSNumber)?.uint64Value ?? 0
        // A wallet can hold one token in several accounts; they are shown as one balance.
        var totals: [String: (raw: UInt64, decimals: Int)] = [:]
        for reply in [try await classic, try await extended] {
            for account in (reply as? [String: Any])?["value"] as? [[String: Any]] ?? [] {
                guard let info = (((account["account"] as? [String: Any])?["data"] as? [String: Any])?["parsed"] as? [String: Any])?["info"] as? [String: Any],
                      let mint = info["mint"] as? String,
                      let amount = info["tokenAmount"] as? [String: Any],
                      let raw = (amount["amount"] as? String).flatMap(UInt64.init), raw > 0,
                      let decimals = (amount["decimals"] as? NSNumber)?.intValue else { continue }
                totals[mint] = (raw: (totals[mint]?.raw ?? 0) + raw, decimals: decimals)
            }
        }
        result.holdings = totals.map { mint, total in
            SolanaHolding(mint: mint, amount: Double(total.raw) / pow(10, Double(total.decimals)), raw: total.raw, decimals: total.decimals)
        }
        .sorted { $0.mint < $1.mint }
        return result
    }

    /// Waits for the transaction to be in a block. Throws when it fails on chain or never shows up.
    /// The first sighting ("processed") is enough to call it landed: balances are re-read afterwards either way.
    static func confirm(_ signature: String, timeout: Duration = .seconds(40)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let reply = try? await call("getSignatureStatuses", [[signature]], timeout: 6)
            if let status = ((reply as? [String: Any])?["value"] as? [Any])?.first as? [String: Any] {
                if let error = status["err"], !(error is NSNull) {
                    throw SolanaError.failedOnChain(describe(error))
                }
                if status["confirmationStatus"] is String { return }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SolanaError.notLanded
    }

    /// Runs a transaction against the chain's current state without sending it.
    static func simulate(_ transaction: Data) async throws -> (error: String?, logs: [String]) {
        let reply = try await call("simulateTransaction", [
            transaction.base64EncodedString(),
            ["encoding": "base64", "sigVerify": false, "replaceRecentBlockhash": true, "commitment": "processed"],
        ])
        let value = (reply as? [String: Any])?["value"] as? [String: Any] ?? [:]
        let error = value["err"].flatMap { $0 is NSNull ? nil : describe($0) }
        return (error, value["logs"] as? [String] ?? [])
    }

    static func send(_ transaction: Data) async throws {
        _ = try await call("sendTransaction", [
            transaction.base64EncodedString(), ["encoding": "base64", "skipPreflight": true, "maxRetries": 5],
        ])
    }

    private static func describe(_ error: Any) -> String {
        if let text = error as? String { return text }
        // The usual shape is {"InstructionError":[2,{"Custom":6001}]}; 6001 is the router's "slippage exceeded".
        if let data = try? JSONSerialization.data(withJSONObject: error), let text = String(data: data, encoding: .utf8) {
            return text.contains("6001") ? "price moved past your slippage" : text
        }
        return "unknown error"
    }
}

// MARK: - Swaps

/// A priced route for one swap, from Jupiter.
struct SolanaQuote: @unchecked Sendable {
    let raw: [String: Any]
    let inAmount: UInt64
    let outAmount: UInt64
    /// The least the swap may return before it fails instead.
    let minimumOut: UInt64
    let priceImpact: Double
}

/// Swap routing through Jupiter's public API. It returns a ready transaction for the wallet to sign.
enum Jupiter {
    private static let hosts = ["https://api.jup.ag/swap/v1", "https://lite-api.jup.ag/swap/v1"]

    /// Jupiter's name for each exchange program ("Whirlpool", "Raydium CLMM"), read once.
    private static let labels = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func label(program: String) async throws -> String? {
        if let known = labels.withLock({ $0[program] }) { return known }
        let root = try await request { host in URLRequest(url: URL(string: "\(host)/program-id-to-label")!, timeoutInterval: 10) }
        let fresh = root.compactMapValues { $0 as? String }
        if !fresh.isEmpty { labels.withLock { $0 = fresh } }
        return fresh[program]
    }

    /// With `pool`, the swap is one hop through that pool and nothing else: the router is held to the pool's
    /// exchange and to direct routes, and a quote that would go through any other pool is refused.
    static func quote(
        input: String, output: String, amount: UInt64, slippageBps: Int, maxAccounts: Int = 56, pool: SolanaPool? = nil
    ) async throws -> SolanaQuote {
        var query = "inputMint=\(input)&outputMint=\(output)&amount=\(amount)&slippageBps=\(slippageBps)&maxAccounts=\(maxAccounts)"
        if let pool {
            guard let label = try await label(program: pool.program),
                  let encoded = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw SolanaError.noRoute("the router does not trade on \(pool.exchange), so this pool cannot be traded from here.")
            }
            query += "&onlyDirectRoutes=true&dexes=\(encoded)"
        } else {
            query += "&restrictIntermediateTokens=true"
        }
        let root = try await request { host in URLRequest(url: URL(string: "\(host)/quote?\(query)")!, timeoutInterval: 10) }
        guard let out = (root["outAmount"] as? String).flatMap(UInt64.init), out > 0 else {
            let reason = root["error"] as? String ?? root["message"] as? String ?? "nothing trades this pair right now."
            throw SolanaError.noRoute(pool.map { "\(reason) (The swap is held to this \($0.exchange) pool.)" } ?? reason)
        }
        if let pool {
            let hops = (root["routePlan"] as? [[String: Any]] ?? []).compactMap { ($0["swapInfo"] as? [String: Any])?["ammKey"] as? String }
            guard hops == [pool.address] else {
                let other = hops.first.map { " (\($0.prefix(6))…)" } ?? ""
                throw SolanaError.noRoute("the router would use another \(pool.exchange) pool\(other), not this one. Nothing was sent.")
            }
        }
        return SolanaQuote(
            raw: root,
            inAmount: (root["inAmount"] as? String).flatMap(UInt64.init) ?? amount,
            outAmount: out,
            minimumOut: (root["otherAmountThreshold"] as? String).flatMap(UInt64.init) ?? out,
            priceImpact: (root["priceImpactPct"] as? String).flatMap(Double.init) ?? 0
        )
    }

    /// The swap as an unsigned transaction paid by `owner`.
    static func transaction(for quote: SolanaQuote, owner: String, priorityLamports: UInt64) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: [
            "quoteResponse": quote.raw,
            "userPublicKey": owner,
            "wrapAndUnwrapSol": true,
            "dynamicComputeUnitLimit": true,
            "prioritizationFeeLamports": priorityLamports,
        ] as [String: Any])
        let root = try await request { host in
            var request = URLRequest(url: URL(string: "\(host)/swap")!, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        guard let encoded = root["swapTransaction"] as? String, let data = Data(base64Encoded: encoded) else {
            throw SolanaError.noRoute(root["error"] as? String ?? root["message"] as? String ?? "the router returned no transaction.")
        }
        return data
    }

    private static func request(_ make: (String) -> URLRequest) async throws -> [String: Any] {
        var last: Error = SolanaError.noRoute("the router is unreachable.")
        for host in hosts {
            do {
                let (data, response) = try await URLSession.shared.data(for: make(host))
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // A 4xx with a message is the router's answer (no route, bad amount); only server trouble tries the next host.
                if let http = response as? HTTPURLResponse, http.statusCode >= 500 || http.statusCode == 429 || http.statusCode == 401 {
                    last = SolanaError.noRoute(root["error"] as? String ?? root["message"] as? String ?? "the router is busy (\(http.statusCode)).")
                    continue
                }
                return root
            } catch {
                last = error
            }
        }
        throw last
    }
}

// MARK: - Nozomi

/// Temporal's Nozomi: a transaction-landing service. It takes a signed transaction that pays one of
/// its tip accounts and gets it to the block leader faster than a public RPC.
enum Nozomi {
    static let host = "https://nozomi.temporal.xyz"
    /// Below this a transaction is silently dropped.
    static let minimumTipLamports: UInt64 = 1_000_000

    static let tipAccounts = [
        "TEMPaMeCRFAS9EKF53Jd6KpHxgL47uWLcpFArU1Fanq",
        "noz3jAjPiHuBPqiSPkkugaJDkJscPuRhYnSpbi8UvC4",
        "noz3str9KXfpKknefHji8L1mPgimezaiUyCHYMDv1GE",
        "noz6uoYCDijhu1V7cutCpwxNiSovEwLdRHPwmgCGDNo",
        "noz9EPNcT7WH6Sou3sr3GGjHQYVkN3DNirpbvDkv9YJ",
        "nozc5yT15LazbLTFVZzoNZCwjh3yUtW86LoUyqsBu4L",
        "nozFrhfnNGoyqwVuwPAW4aaGqempx4PU6g6D9CJMv7Z",
        "nozievPk7HyK1Rqy1MPJwVQ7qQg2QoJGyP71oeDwbsu",
        "noznbgwYnBLDHu8wcQVCEw6kDrXkPdKkydGJGNXGvL7",
        "nozNVWs5N8mgzuD3qigrCG2UoKxZttxzZ85pvAQVrbP",
        "nozpEGbwx4BcGp6pvEdAh1JoC2CQGZdU6HbNP1v2p6P",
        "nozrhjhkCr3zXT3BiT4WCodYCUFeQvcdUkM7MqhKqge",
        "nozrwQtWhEdrA6W8dkbt9gnUaMs52PdAv5byipnadq3",
        "nozUacTVWub3cL4mJmGCYjKZTnE9RbdY5AP46iQgbPJ",
        "nozWCyTPppJjRuw2fpzDhhWbW355fzosWSzrrMYB1Qk",
        "nozWNju6dY353eMkMqURqwQEoM3SFgEKC6psLCSfUne",
        "nozxNBgWohjR75vdspfxR5H9ceC7XXH99xpxhVGt3Bb",
    ]

    static var hasKey: Bool { KeychainStore.nozomi.readAPIKey() != nil }

    /// A different tip account for each transaction, as Nozomi asks.
    static func randomTipAccount() -> Data {
        Base58.decode(tipAccounts.randomElement()!)!
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Sends a signed transaction. Nozomi replies with an empty 200 and retries on its side until the
    /// transaction lands or its blockhash expires, so it is sent exactly once.
    static func send(_ transaction: Data, key: String) async throws {
        var request = URLRequest(url: URL(string: "\(host)/api/sendTransaction2?c=\(key)")!)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(transaction.base64EncodedString().utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SolanaError.rpc("Nozomi did not answer.") }
        switch http.statusCode {
        case 200: return
        case 401: throw SolanaError.rpc("Nozomi rejected the API key. Check it in Settings → Solana.")
        case 429: throw SolanaError.rpc("Nozomi is rate limiting this key.")
        default:
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SolanaError.rpc("Nozomi refused the transaction (\(http.statusCode))\(text.isEmpty ? "" : ": \(text)").")
        }
    }

    /// Keeps the connection open so the next order does not pay for a new handshake.
    static func warm() async {
        guard hasKey, let url = URL(string: "\(host)/ping") else { return }
        _ = try? await session.data(from: url)
    }
}
