import Foundation
import os

// MARK: - Action values

/// A JSON-like value whose map keys keep their order. Hyperliquid hashes the MessagePack encoding
/// of an action, so the key order must match the reference SDK exactly.
indirect enum HLValue: Sendable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case array([HLValue])
    case map([(String, HLValue)])
    case null

    /// MessagePack, choosing the smallest encoding for each value as the reference SDK does.
    var messagePack: Data {
        var out = Data()
        pack(into: &out)
        return out
    }

    private func pack(into out: inout Data) {
        switch self {
        case .null:
            out.append(0xC0)
        case let .bool(value):
            out.append(value ? 0xC3 : 0xC2)
        case let .int(value):
            if value >= 0 {
                switch value {
                case 0..<0x80: out.append(UInt8(value))
                case 0..<0x100: out.append(0xCC); out.append(UInt8(value))
                case 0..<0x1_0000: out.append(0xCD); Self.append(UInt64(value), bytes: 2, to: &out)
                case 0..<0x1_0000_0000: out.append(0xCE); Self.append(UInt64(value), bytes: 4, to: &out)
                default: out.append(0xCF); Self.append(UInt64(value), bytes: 8, to: &out)
                }
            } else if value >= -32 {
                out.append(UInt8(bitPattern: Int8(value)))
            } else {
                out.append(0xD3)
                Self.append(UInt64(bitPattern: value), bytes: 8, to: &out)
            }
        case let .string(value):
            let bytes = Data(value.utf8)
            switch bytes.count {
            case 0..<32: out.append(0xA0 | UInt8(bytes.count))
            case 0..<0x100: out.append(0xD9); out.append(UInt8(bytes.count))
            default: out.append(0xDA); Self.append(UInt64(bytes.count), bytes: 2, to: &out)
            }
            out.append(bytes)
        case let .array(values):
            if values.count < 16 {
                out.append(0x90 | UInt8(values.count))
            } else {
                out.append(0xDC)
                Self.append(UInt64(values.count), bytes: 2, to: &out)
            }
            values.forEach { $0.pack(into: &out) }
        case let .map(pairs):
            if pairs.count < 16 {
                out.append(0x80 | UInt8(pairs.count))
            } else {
                out.append(0xDE)
                Self.append(UInt64(pairs.count), bytes: 2, to: &out)
            }
            for (key, value) in pairs {
                HLValue.string(key).pack(into: &out)
                value.pack(into: &out)
            }
        }
    }

    private static func append(_ value: UInt64, bytes: Int, to out: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    var json: String {
        switch self {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .string(value): Self.quote(value)
        case let .array(values): "[" + values.map(\.json).joined(separator: ",") + "]"
        case let .map(pairs): "{" + pairs.map { Self.quote($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Signing

/// Hyperliquid "L1 action" signing: hash the action, wrap the hash in a phantom `Agent` struct,
/// and sign that as EIP-712 typed data. Checked against the official Python SDK's output in the tests.
enum HLSigning {
    /// keccak(msgpack(action) ‖ nonce ‖ vault marker).
    static func actionHash(_ action: HLValue, nonce: Int64, vaultAddress: String? = nil) -> Data {
        var data = action.messagePack
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: UInt64(nonce) >> UInt64(shift)))
        }
        if let vaultAddress, let bytes = Data(hex: vaultAddress) {
            data.append(0x01)
            data.append(bytes)
        } else {
            data.append(0x00)
        }
        return Keccak256.hash(data)
    }

    /// The 32-byte EIP-712 digest for an action hash.
    static func digest(actionHash: Data, isMainnet: Bool) -> Data {
        func hash(_ string: String) -> Data { Keccak256.hash(Data(string.utf8)) }
        func word(_ value: UInt64) -> Data {
            var data = Data(repeating: 0, count: 24)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
            return data
        }

        let domain = Keccak256.hash(
            hash("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                + hash("Exchange")
                + hash("1")
                + word(1_337)
                + Data(repeating: 0, count: 32)
        )
        let agent = Keccak256.hash(
            hash("Agent(string source,bytes32 connectionId)")
                + hash(isMainnet ? "a" : "b")
                + actionHash
        )
        return Keccak256.hash(Data([0x19, 0x01]) + domain + agent)
    }

    /// Digest for moving USDC between the spot and perp balances. Unlike orders this is a
    /// "user-signed" action: plain EIP-712 over its fields, and only the account's own key may sign it.
    static func usdClassTransferDigest(amount: String, toPerp: Bool, nonce: Int64, isMainnet: Bool = true) -> Data {
        func hash(_ string: String) -> Data { Keccak256.hash(Data(string.utf8)) }
        func word(_ value: UInt64) -> Data {
            var data = Data(repeating: 0, count: 24)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
            return data
        }

        let domain = Keccak256.hash(
            hash("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                + hash("HyperliquidSignTransaction")
                + hash("1")
                + word(HLAction.signatureChainID)
                + Data(repeating: 0, count: 32)
        )
        let message = Keccak256.hash(
            hash("HyperliquidTransaction:UsdClassTransfer(string hyperliquidChain,string amount,bool toPerp,uint64 nonce)")
                + hash(isMainnet ? "Mainnet" : "Testnet")
                + hash(amount)
                + word(toPerp ? 1 : 0)
                + word(UInt64(nonce))
        )
        return Keccak256.hash(Data([0x19, 0x01]) + domain + message)
    }

    static func sign(_ action: HLValue, nonce: Int64, privateKey: Data, isMainnet: Bool = true) throws -> EthSignature {
        try EthKey.sign(
            digest: digest(actionHash: actionHash(action, nonce: nonce), isMainnet: isMainnet),
            with: privateKey
        )
    }
}

// MARK: - Actions

enum HLTimeInForce: String, Sendable {
    /// Fill what crosses now and cancel the rest: how market orders are sent.
    case ioc = "Ioc"
    /// Rest on the book until filled or cancelled.
    case gtc = "Gtc"
}

enum HLAction {
    /// The chain id user-signed actions are signed under (any is accepted; this is the SDK's).
    static let signatureChainID: UInt64 = 0x66eee

    static func usdClassTransfer(amount: String, toPerp: Bool, nonce: Int64, isMainnet: Bool = true) -> HLValue {
        .map([
            ("type", .string("usdClassTransfer")),
            ("amount", .string(amount)),
            ("toPerp", .bool(toPerp)),
            ("nonce", .int(nonce)),
            ("signatureChainId", .string("0x66eee")),
            ("hyperliquidChain", .string(isMainnet ? "Mainnet" : "Testnet")),
        ])
    }

    static func order(asset: Int, isBuy: Bool, price: String, size: String, reduceOnly: Bool, tif: HLTimeInForce) -> HLValue {
        .map([
            ("type", .string("order")),
            ("orders", .array([
                .map([
                    ("a", .int(Int64(asset))),
                    ("b", .bool(isBuy)),
                    ("p", .string(price)),
                    ("s", .string(size)),
                    ("r", .bool(reduceOnly)),
                    ("t", .map([("limit", .map([("tif", .string(tif.rawValue))]))])),
                ]),
            ])),
            ("grouping", .string("na")),
        ])
    }

    static func cancel(asset: Int, orderID: Int64) -> HLValue {
        .map([
            ("type", .string("cancel")),
            ("cancels", .array([.map([("a", .int(Int64(asset))), ("o", .int(orderID))])])),
        ])
    }

    static func updateLeverage(asset: Int, isCross: Bool, leverage: Int) -> HLValue {
        .map([
            ("type", .string("updateLeverage")),
            ("asset", .int(Int64(asset))),
            ("isCross", .bool(isCross)),
            ("leverage", .int(Int64(leverage))),
        ])
    }
}

/// Number formatting the exchange accepts.
enum HLWire {
    /// Up to 8 decimals with trailing zeros removed, as the reference SDK sends numbers.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// Prices may have 5 significant figures and at most `6 - szDecimals` decimals; whole numbers are always valid.
    /// (`maxDecimals` is 6 for perps and 8 for spot.)
    static func price(_ value: Double, szDecimals: Int, maxDecimals: Int = 6) -> Double {
        guard value > 0, value.isFinite else { return 0 }
        if value == value.rounded() { return value }
        let significant = Double(String(format: "%.5g", value)) ?? value
        let scale = pow(10, Double(max(maxDecimals - szDecimals, 0)))
        return (significant * scale).rounded() / scale
    }

    /// Sizes are cut down to the market's size step so an order never exceeds what was typed.
    static func size(_ value: Double, szDecimals: Int) -> Double {
        let scale = pow(10, Double(szDecimals))
        return ((value * scale) + 1e-9).rounded(.down) / scale
    }
}

// MARK: - Account data

struct HLPosition: Equatable, Identifiable, Sendable {
    let coin: String
    /// Signed: positive is long, negative short.
    let size: Double
    let entryPrice: Double
    let value: Double
    let unrealizedPnl: Double
    let liquidationPrice: Double?
    let leverage: Int
    let isCross: Bool

    var id: String { coin }
}

struct HLOpenOrder: Equatable, Identifiable, Sendable {
    let coin: String
    let isBuy: Bool
    let price: Double
    let size: Double
    let id: Int64
}

/// A spot token balance. Token 0 is USDC.
struct HLSpotBalance: Equatable, Sendable {
    let coin: String
    let token: Int
    let total: Double
    /// What the balance cost, in USDC.
    let entryNotional: Double
}

/// How a spot token trades against USDC.
struct HLSpotPair: Equatable, Sendable {
    let token: Int
    /// Key of its price in the mids feed, e.g. `PURR/USDC` or `@107`.
    let midKey: String
    /// Asset id for orders: 10,000 plus the pair's index.
    let asset: Int
    let szDecimals: Int
}

struct HLAccountState: Equatable, Sendable {
    var accountValue = 0.0
    var withdrawable = 0.0
    var positions: [HLPosition] = []
    var orders: [HLOpenOrder] = []
    var spot: [HLSpotBalance] = []

    /// USDC sitting in the spot balance, which perps cannot use until it is moved across.
    var spotUSDC: Double { spot.first { $0.token == 0 }?.total ?? 0 }
}

enum HLOrderOutcome: Equatable, Sendable {
    case filled(size: Double, price: Double)
    case resting(orderID: Int64)
    case done
}

struct HLExchangeError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Client

enum HyperliquidExchange {
    private static let base = URL(string: "https://api.hyperliquid.xyz")!
    private static let lastNonce = OSAllocatedUnfairLock(initialState: Int64(0))

    /// Millisecond timestamps, forced to be strictly increasing within this process.
    static func nextNonce() -> Int64 {
        lastNonce.withLock { last in
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            last = max(now, last + 1)
            return last
        }
    }

    /// The JSON body for `/exchange`.
    static func body(action: HLValue, nonce: Int64, signature: EthSignature) -> String {
        HLValue.map([
            ("action", action),
            ("nonce", .int(nonce)),
            ("signature", .map([("r", .string(signature.r)), ("s", .string(signature.s)), ("v", .int(Int64(signature.v)))])),
            ("vaultAddress", .null),
        ]).json
    }

    /// Signs and submits an action. Throws `HLExchangeError` with the exchange's own message when it is rejected.
    @discardableResult
    static func send(_ action: HLValue, privateKey: Data) async throws -> HLOrderOutcome {
        let clock = ContinuousClock()
        let started = clock.now
        let nonce = nextNonce()
        let signature = try HLSigning.sign(action, nonce: nonce, privateKey: privateKey)
        let signed = clock.now
        let data = try await post("exchange", body: body(action: action, nonce: nonce, signature: signature), session: tradeSession)
        log("nonce=\(nonce) sign=\(milliseconds(signed - started))ms exchange=\(milliseconds(clock.now - signed))ms")
        return try outcome(from: data)
    }

    /// Orders get their own connections, so one never waits in line behind the quote and balance polls.
    private static let tradeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// Keeps the order connection open (TCP and TLS already done) while a ticket is on screen.
    static func warm() async {
        _ = try? await post("info", body: #"{"type":"exchangeStatus"}"#, session: tradeSession)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Timings of every signed request, in `~/Library/Logs/Powder/orders.log`.
    private static let logURL: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let folder = library.appendingPathComponent("Logs/Powder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("orders.log")
    }()

    static func log(_ line: String) {
        guard let logURL, let data = "\(Date().ISO8601Format()) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Moves USDC between the spot and perp balances. Must be signed by the account's own key.
    static func transferUSDC(amount: Double, toPerp: Bool, privateKey: Data) async throws {
        let nonce = nextNonce()
        let text = HLWire.number(amount)
        let signature = try EthKey.sign(
            digest: HLSigning.usdClassTransferDigest(amount: text, toPerp: toPerp, nonce: nonce), with: privateKey
        )
        let action = HLAction.usdClassTransfer(amount: text, toPerp: toPerp, nonce: nonce)
        _ = try outcome(from: await post("exchange", body: body(action: action, nonce: nonce, signature: signature), session: tradeSession))
    }

    static func outcome(from data: Data) throws -> HLOrderOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HLExchangeError(message: String(data: data, encoding: .utf8) ?? "Unreadable response from Hyperliquid.")
        }
        guard root["status"] as? String == "ok" else {
            throw HLExchangeError(message: root["response"] as? String ?? "Hyperliquid rejected the request.")
        }
        let payload = (root["response"] as? [String: Any])?["data"] as? [String: Any]
        guard let status = (payload?["statuses"] as? [Any])?.first else { return .done }
        if let fields = status as? [String: Any] {
            if let error = fields["error"] as? String { throw HLExchangeError(message: error) }
            if let filled = fields["filled"] as? [String: Any] {
                return .filled(size: number(filled["totalSz"]), price: number(filled["avgPx"]))
            }
            if let resting = fields["resting"] as? [String: Any], let id = resting["oid"] as? NSNumber {
                return .resting(orderID: id.int64Value)
            }
        }
        return .done
    }

    /// Balance, positions and open orders for an account address.
    static func accountState(user: String) async throws -> HLAccountState {
        async let clearing = post("info", body: #"{"type":"clearinghouseState","user":"\#(user)"}"#)
        async let open = post("info", body: #"{"type":"openOrders","user":"\#(user)"}"#)
        async let spot = post("info", body: #"{"type":"spotClearinghouseState","user":"\#(user)"}"#)
        return try parseAccount(clearinghouse: await clearing, openOrders: await open, spot: try? await spot)
    }

    /// The leverage the exchange currently has for this account on a market.
    static func leverage(user: String, coin: String) async throws -> (value: Int, isCross: Bool)? {
        let data = try await post("info", body: #"{"type":"activeAssetData","user":"\#(user)","coin":"\#(coin)"}"#)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let leverage = root["leverage"] as? [String: Any], let value = leverage["value"] as? NSNumber else { return nil }
        return (value.intValue, leverage["type"] as? String != "isolated")
    }

    /// USDC-quoted spot pairs by token index.
    static func spotPairs() async throws -> [Int: HLSpotPair] {
        let data = try await post("info", body: #"{"type":"spotMeta"}"#)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var decimals: [Int: Int] = [:]
        for token in root["tokens"] as? [[String: Any]] ?? [] {
            if let index = token["index"] as? Int, let places = token["szDecimals"] as? Int { decimals[index] = places }
        }
        var pairs: [Int: HLSpotPair] = [:]
        for pair in root["universe"] as? [[String: Any]] ?? [] {
            guard let tokens = pair["tokens"] as? [Int], tokens.count == 2, tokens[1] == 0,
                  let name = pair["name"] as? String, let index = pair["index"] as? Int else { continue }
            pairs[tokens[0]] = HLSpotPair(token: tokens[0], midKey: name, asset: 10_000 + index, szDecimals: decimals[tokens[0]] ?? 0)
        }
        return pairs
    }

    static func parseAccount(clearinghouse: Data, openOrders: Data, spot: Data? = nil) throws -> HLAccountState {
        guard let root = try JSONSerialization.jsonObject(with: clearinghouse) as? [String: Any] else {
            throw HLExchangeError(message: "Unreadable account state from Hyperliquid.")
        }
        var state = HLAccountState()
        state.accountValue = number((root["marginSummary"] as? [String: Any])?["accountValue"])
        state.withdrawable = number(root["withdrawable"])
        for entry in root["assetPositions"] as? [[String: Any]] ?? [] {
            guard let position = entry["position"] as? [String: Any], let coin = position["coin"] as? String else { continue }
            let leverage = position["leverage"] as? [String: Any]
            let size = number(position["szi"])
            guard size != 0 else { continue }
            state.positions.append(HLPosition(
                coin: coin,
                size: size,
                entryPrice: number(position["entryPx"]),
                value: number(position["positionValue"]),
                unrealizedPnl: number(position["unrealizedPnl"]),
                liquidationPrice: (position["liquidationPx"] as? String).flatMap(Double.init),
                leverage: (leverage?["value"] as? NSNumber)?.intValue ?? 1,
                isCross: leverage?["type"] as? String != "isolated"
            ))
        }
        for order in (try? JSONSerialization.jsonObject(with: openOrders)) as? [[String: Any]] ?? [] {
            guard let coin = order["coin"] as? String, let id = order["oid"] as? NSNumber else { continue }
            // Spot orders are listed too; the ticket only handles perps.
            if coin.hasPrefix("@") || coin.contains("/") { continue }
            state.orders.append(HLOpenOrder(
                coin: coin,
                isBuy: order["side"] as? String == "B",
                price: number(order["limitPx"]),
                size: number(order["sz"]),
                id: id.int64Value
            ))
        }
        let spotRoot = spot.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        for balance in spotRoot?["balances"] as? [[String: Any]] ?? [] {
            guard let coin = balance["coin"] as? String, let token = balance["token"] as? Int else { continue }
            let total = number(balance["total"])
            guard total > 0 else { continue }
            state.spot.append(HLSpotBalance(coin: coin, token: token, total: total, entryNotional: number(balance["entryNtl"])))
        }
        return state
    }

    private static func number(_ value: Any?) -> Double {
        if let string = value as? String { return Double(string) ?? 0 }
        return (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func post(_ path: String, body: String, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            throw HLExchangeError(message: text ?? "Hyperliquid returned HTTP \(http.statusCode).")
        }
        return data
    }
}
