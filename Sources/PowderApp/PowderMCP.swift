import Foundation
import Network
import SwiftUI

// MARK: - Server

/// A Model Context Protocol server on localhost, speaking the "streamable HTTP" transport with plain
/// JSON replies. The ⌘K assistant's CLI is pointed at it, so the model can arrange the workspace and
/// read market data. The URL carries a random token; nothing else on the machine is told it, apart
/// from a file only this user can read.
@MainActor
final class PowderMCPServer {
    private var listener: NWListener?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private(set) var url: String?
    var tools: PowderTools?

    static let serverName = "powder"

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                self?.pump(connection, buffer: Data())
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard case .ready = state, let self, let port = listener?.port else { return }
                self.url = "http://127.0.0.1:\(port.rawValue)/mcp/\(self.token)"
                self.publishURL()
            }
        }
        listener.start(queue: .main)
    }

    /// Lets the user's own agents connect too: `~/Library/Application Support/Powder/mcp.json`, readable only by them.
    private func publishURL() {
        guard let url, let folder = Self.supportFolder else { return }
        let file = folder.appendingPathComponent("mcp.json")
        let body = #"{"mcpServers":{"powder":{"type":"http","url":"\#(url)"}}}"#
        try? Data(body.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static var supportFolder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Powder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: HTTP

    private struct Request {
        let method: String
        let path: String
        let body: Data
        /// Bytes of the buffer this request used.
        let length: Int

        init?(_ buffer: Data) {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let lines = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let start = lines.first?.split(separator: " ") ?? []
            guard start.count >= 2 else { return nil }
            var contentLength = 0
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.endIndex - bodyStart >= contentLength else { return nil }
            method = String(start[0])
            path = String(start[1])
            body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
            length = (bodyStart - buffer.startIndex) + contentLength
        }
    }

    /// Answers every complete request in `buffer`, then waits for more bytes.
    private func pump(_ connection: NWConnection, buffer: Data) {
        if let request = Request(buffer) {
            let rest = Data(buffer.dropFirst(request.length))
            Task { @MainActor in
                let response = await self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                    MainActor.assumeIsolated { self?.pump(connection, buffer: rest) }
                })
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let data, !data.isEmpty, error == nil else { return connection.cancel() }
                if isComplete, Request(buffer + data) == nil { return connection.cancel() }
                self.pump(connection, buffer: buffer + data)
            }
        }
    }

    private func respond(to request: Request) async -> Data {
        guard request.path == "/mcp/\(token)" else { return Self.http(404, "Not Found") }
        guard request.method == "POST" else { return Self.http(405, "Method Not Allowed", headers: "Allow: POST\r\n") }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            return Self.http(400, "Bad Request")
        }
        var replies: [[String: Any]] = []
        for message in (json as? [[String: Any]]) ?? [(json as? [String: Any]) ?? [:]] {
            if let reply = await handle(message) { replies.append(reply) }
        }
        guard !replies.isEmpty else { return Self.http(202, "Accepted") }
        let payload: Any = json is [Any] ? replies : replies[0]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return Self.http(200, "OK", headers: "Content-Type: application/json\r\n", body: body)
    }

    private static func http(_ status: Int, _ reason: String, headers: String = "", body: Data = Data()) -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\n\(headers)Content-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n".utf8) + body
    }

    // MARK: JSON-RPC

    /// Returns nil for notifications, which get no reply.
    private func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String, let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }

        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": "1.0"],
                "instructions": PowderTools.instructions,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": PowderTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let tools else { return result(["content": [["type": "text", "text": "Powder is not ready."]], "isError": true]) }
            do {
                let text = try await tools.call(name, arguments)
                return result(["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }
}

// MARK: - Tools

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What the assistant can do: arrange panes and tabs, set up charts, and read markets and accounts.
/// There is deliberately no tool that places, cancels or closes an order, or that touches a key.
@MainActor
final class PowderTools {
    private weak var router: AppRouter?

    init(router: AppRouter) {
        self.router = router
    }

    static let instructions = """
    Powder is a macOS trading terminal for Hyperliquid perpetuals. The window is a tree of panes; each pane has tabs. \
    A tab is a market (named by its coin, e.g. BTC), one of the views "markets", "positions", "launchpad", or a web page (named web:<url>). \
    Call get_layout before rearranging. Panes are numbered left-to-right, top-to-bottom, starting at 1, and renumber after every change. \
    These tools cannot place or cancel orders.
    """

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private static func string(_ description: String, options: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let options { schema["enum"] = options }
        return schema
    }

    private static let intervals = HLInterval.allCases.map(\.rawValue)

    static let definitions: [[String: Any]] = [
        tool("get_layout", "The window's panes and tabs, which are selected and active, each market tab's chart settings, and the theme."),
        tool("open_market", "Show a perp market. Reuses its tab if already open (placement 'tab'); otherwise opens it in the active pane or in a new split beside it.", [
            "coin": string("Market symbol, e.g. BTC, ETH, HYPE."),
            "placement": string("Where to put it. Default 'tab'.", options: ["tab", "split_right", "split_down"]),
            "pane": ["type": "integer", "description": "Pane number to open in or split from. Default: the active pane."],
        ], required: ["coin"]),
        tool("open_view", "Show the all-markets table, the positions table, or the Solana launchpad.", [
            "view": string("Which view.", options: ["markets", "positions", "launchpad"]),
        ], required: ["view"]),
        tool("open_web", "Open a website in a new web tab in the active pane (or the given pane).", [
            "address": string("A URL, a bare domain like x.com/someone, or words to search for."),
            "pane": ["type": "integer", "description": "Pane number. Default: the active pane."],
        ], required: ["address"]),
        tool("focus", "Select a tab by name, or make a pane active.", [
            "tab": string("Tab name: a coin, or markets / positions / launchpad."),
            "pane": ["type": "integer", "description": "Pane number."],
        ]),
        tool("close_tab", "Close a tab. A pane closes with its last tab. The window's final tab cannot be closed.", [
            "tab": string("Tab name: a coin, or markets / positions / launchpad."),
            "pane": ["type": "integer", "description": "Pane number, if the name is open in more than one pane."],
        ], required: ["tab"]),
        tool("move_tab", "Move a tab into another pane, or split that pane with it.", [
            "tab": string("Tab name."),
            "to_pane": ["type": "integer", "description": "Destination pane number."],
            "zone": string("'center' adds it to the pane's tabs; a side splits the pane and puts the tab there. Default 'center'.", options: ["center", "left", "right", "top", "bottom"]),
        ], required: ["tab", "to_pane"]),
        tool("arrange", "Whole-window layout commands.", [
            "command": string("'equalize' makes all panes the same size; 'reset' restores the default layout.", options: ["equalize", "reset"]),
        ], required: ["command"]),
        tool("set_chart", "Change an open market tab's chart. Only the fields given are changed.", [
            "coin": string("The market tab to change."),
            "interval": string("Candle length.", options: intervals),
            "style": string("Chart type.", options: ChartStyle.allCases.map(\.rawValue)),
            "indicators": ["type": "array", "items": ["type": "string", "enum": ChartIndicator.allCases.map(\.rawValue)],
                           "description": "The full set of indicators to show; others are turned off."],
            "log_scale": ["type": "boolean", "description": "Logarithmic price axis."],
        ], required: ["coin"]),
        tool("set_theme", "Switch the app between dark and light.", [
            "theme": string("Theme.", options: ["dark", "light"]),
        ], required: ["theme"]),
        tool("list_markets", "Live Hyperliquid perp markets: price, 24h change, hourly funding, 24h volume, open interest, max leverage.", [
            "query": string("Only symbols containing this text."),
            "sort_by": string("Default 'volume'.", options: ["volume", "change", "funding", "open_interest", "price", "name"]),
            "ascending": ["type": "boolean", "description": "Default false (largest first)."],
            "limit": ["type": "integer", "description": "Default 20, at most 250."],
        ]),
        tool("get_candles", "OHLCV candles for a perp market, oldest first.", [
            "coin": string("Market symbol."),
            "interval": string("Candle length. Default 1h.", options: intervals),
            "count": ["type": "integer", "description": "How many, most recent. Default 100, at most 500."],
        ], required: ["coin"]),
        tool("search_solana_tokens", "Search Solana tokens by name, symbol or mint address (Codex data): price, 24h change, volume, liquidity, market cap, holders.", [
            "query": string("Name, symbol or mint address."),
            "limit": ["type": "integer", "description": "Default 8, at most 25."],
        ], required: ["query"]),
        tool("get_solana_token", "One Solana token by mint address: live figures, recent candles and the latest swaps in its main pool.", [
            "address": string("Mint address."),
            "interval": string("Candle length. Default 15m.", options: SolanaAPI.intervals.map(\.rawValue)),
            "candles": ["type": "integer", "description": "How many candles. Default 30, at most 300."],
        ], required: ["address"]),
        tool("open_solana_token", "Open a Solana token in a market tab (chart and swap tape; no order book, no trading). Reuses its tab if already open.", [
            "address": string("Mint address. Use search_solana_tokens to find it."),
            "pane": ["type": "integer", "description": "Pane number. Default: the active pane."],
        ], required: ["address"]),
        tool("get_accounts", "Every wallet in the app (name and public address only): balances, open perp positions with live PnL and liquidation price, spot holdings, and resting orders."),
        tool("screenshot", "Save a picture of the Powder window as a PNG in Powder's support folder and return its path. Web tabs may come out blank."),
    ]

    /// The app draws its own window, so this needs no Screen Recording permission.
    private func screenshot() throws -> String {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let content = window.contentView else { throw ToolError("Powder has no open window.") }
        let view = content.superview ?? content
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ToolError("The window could not be drawn.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]),
              let folder = PowderMCPServer.supportFolder else { throw ToolError("The picture could not be saved.") }
        let file = folder.appendingPathComponent("screenshot.png")
        try data.write(to: file, options: .atomic)
        return file.path
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        guard let router else { throw ToolError("Powder is closing.") }
        switch name {
        case "get_layout":
            return json(layout(router))

        case "open_market":
            let coin = try market(arguments["coin"], in: router).name
            if let pane = arguments["pane"] { router.activate(try group(pane, in: router)) }
            switch arguments["placement"] as? String ?? "tab" {
            case "split_right": router.split(.horizontal, coin: coin)
            case "split_down": router.split(.vertical, coin: coin)
            default: router.open(coin: coin)
            }
            return json(layout(router))

        case "open_view":
            switch arguments["view"] as? String {
            case "markets": router.openMarkets()
            case "positions": router.openPositions()
            case "launchpad": router.openLaunchpad()
            default: throw ToolError("view must be markets, positions or launchpad.")
            }
            return json(layout(router))

        case "open_web":
            guard let address = arguments["address"] as? String, !address.isEmpty else { throw ToolError("Give an address.") }
            if let pane = arguments["pane"] { router.activate(try group(pane, in: router)) }
            router.openWeb(address)
            return json(layout(router))

        case "focus":
            if let tab = arguments["tab"] {
                let found = try find(tab, pane: arguments["pane"], in: router)
                router.select(found.tab.id, in: found.group)
            } else if let pane = arguments["pane"] {
                router.activate(try group(pane, in: router))
            } else {
                throw ToolError("Give a tab or a pane.")
            }
            return json(layout(router))

        case "close_tab":
            let found = try find(arguments["tab"], pane: arguments["pane"], in: router)
            guard router.groups.reduce(0, { $0 + $1.tabs.count }) > 1 else { throw ToolError("The last tab cannot be closed.") }
            router.close(found.tab.id, in: found.group)
            return json(layout(router))

        case "move_tab":
            let found = try find(arguments["tab"], pane: nil, in: router)
            let target = try group(arguments["to_pane"], in: router)
            let zone: DropZone = switch arguments["zone"] as? String ?? "center" {
            case "left": .left
            case "right": .right
            case "top": .top
            case "bottom": .bottom
            default: .center
            }
            router.move(tab: found.tab.id, to: target, zone: zone)
            return json(layout(router))

        case "arrange":
            switch arguments["command"] as? String {
            case "equalize": router.equalize()
            case "reset": router.resetLayout()
            default: throw ToolError("command must be equalize or reset.")
            }
            return json(layout(router))

        case "set_chart":
            let found = try find(arguments["coin"], pane: nil, in: router)
            guard let model = found.tab.market else { throw ToolError("That tab is not a market.") }
            if let raw = arguments["interval"] as? String {
                guard let interval = HLInterval(rawValue: raw) else { throw ToolError("Unknown interval \(raw).") }
                model.setInterval(interval)
            }
            if let raw = arguments["style"] as? String {
                guard let style = ChartStyle(rawValue: raw) else { throw ToolError("Unknown style \(raw).") }
                model.setStyle(style)
            }
            if let raw = arguments["indicators"] as? [String] {
                let wanted = Set(raw.compactMap(ChartIndicator.init))
                for indicator in ChartIndicator.allCases where wanted.contains(indicator) != model.chartSettings.indicators.contains(indicator) {
                    model.toggle(indicator)
                }
            }
            if let log = arguments["log_scale"] as? Bool { model.chartSettings.logScale = log }
            return json(tabInfo(found.tab, selected: found.group.selectedID == found.tab.id))

        case "set_theme":
            guard let theme = (arguments["theme"] as? String).flatMap(AppTheme.init) else { throw ToolError("theme must be dark or light.") }
            router.setTheme(theme)
            return "Theme is now \(theme.rawValue)."

        case "list_markets":
            return json(markets(arguments, in: router))

        case "get_candles":
            let coin = try market(arguments["coin"], in: router).name
            let raw = arguments["interval"] as? String ?? "1h"
            guard let interval = HLInterval(rawValue: raw) else { throw ToolError("Unknown interval \(raw).") }
            let count = min(max(Self.int(arguments["count"]) ?? 100, 1), 500)
            let candles = try await HyperliquidAPI.candles(coin: coin, interval: interval, count: count)
            return json([
                "coin": coin, "interval": raw, "columns": ["time_utc", "open", "high", "low", "close", "volume"],
                "candles": candles.suffix(count).map { candle -> [Any] in
                    [Date(timeIntervalSince1970: Double(candle.t) / 1_000).ISO8601Format(), candle.o, candle.h, candle.l, candle.c, candle.v]
                },
            ])

        case "search_solana_tokens":
            guard let query = arguments["query"] as? String, !query.isEmpty else { throw ToolError("Give a query.") }
            let found = try await SolanaAPI.search(query, limit: min(max(Self.int(arguments["limit"]) ?? 8, 1), 25))
            return json(["tokens": found.map(solanaInfo)])

        case "get_solana_token":
            guard let address = arguments["address"] as? String, let stats = try await SolanaAPI.stats(address: address) else {
                throw ToolError("Codex has no Solana token at that address.")
            }
            let raw = arguments["interval"] as? String ?? "15m"
            guard let interval = HLInterval(rawValue: raw), SolanaAPI.intervals.contains(interval) else { throw ToolError("Unknown interval \(raw).") }
            let count = min(max(Self.int(arguments["candles"]) ?? 30, 1), 300)
            let candles = try await SolanaAPI.bars(token: stats.token, interval: interval, count: count)
            var trades: [HLTrade] = []
            if let pair = stats.pairAddress { trades = try await SolanaAPI.trades(pair: pair, symbol: stats.token.symbol, limit: 20) }
            var info = solanaInfo(stats)
            info["interval"] = raw
            info["candle_columns"] = ["time_utc", "open", "high", "low", "close", "volume_usd"]
            info["candles"] = candles.suffix(count).map { candle -> [Any] in
                [Date(timeIntervalSince1970: Double(candle.t) / 1_000).ISO8601Format(), candle.o, candle.h, candle.l, candle.c, candle.v]
            }
            info["recent_swaps"] = trades.map { trade -> [String: Any] in
                ["time_utc": Date(timeIntervalSince1970: Double(trade.time) / 1_000).ISO8601Format(),
                 "side": trade.isBuy ? "buy" : "sell", "price_usd": trade.px, "tokens": trade.sz]
            }
            return json(info)

        case "open_solana_token":
            guard let address = arguments["address"] as? String, let stats = try await SolanaAPI.stats(address: address) else {
                throw ToolError("Codex has no Solana token at that address.")
            }
            if let pane = arguments["pane"] { router.activate(try group(pane, in: router)) }
            router.open(solana: stats.token)
            return json(layout(router))

        case "get_accounts":
            return json(await accounts(in: router))

        case "screenshot":
            return try screenshot()

        default:
            throw ToolError("Unknown tool \(name).")
        }
    }

    // MARK: Layout

    private func name(of tab: WorkspaceTab) -> String {
        tab.market?.coin ?? tab.savedName
    }

    private func tabInfo(_ tab: WorkspaceTab, selected: Bool) -> [String: Any] {
        var info: [String: Any] = ["tab": name(of: tab), "kind": tab.market == nil ? "view" : "market", "selected": selected]
        if let model = tab.market {
            info["interval"] = model.interval.rawValue
            info["chart_style"] = model.chartSettings.style.rawValue
            info["indicators"] = model.chartSettings.indicators.map(\.rawValue).sorted()
            info["log_scale"] = model.chartSettings.logScale
        }
        return info
    }

    private func layout(_ router: AppRouter) -> [String: Any] {
        var number = 0
        func describe(_ node: LayoutNode) -> [String: Any] {
            switch node {
            case let .group(group):
                number += 1
                return [
                    "pane": number, "active": group.id == router.activeGroupID,
                    "tabs": group.tabs.map { tabInfo($0, selected: $0.id == group.selectedID) },
                ]
            case let .split(box):
                return [
                    "split": box.axis == .horizontal ? "side_by_side" : "stacked",
                    "sizes": box.fractions.map { (Double($0) * 100).rounded() / 100 },
                    "children": box.children.map(describe),
                ]
            }
        }
        return ["theme": router.theme.rawValue, "layout": describe(router.root)]
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }

    private func group(_ value: Any?, in router: AppRouter) throws -> PaneGroup {
        let groups = router.groups
        guard let number = Self.int(value), groups.indices.contains(number - 1) else {
            throw ToolError("There is no pane \(value.map { "\($0)" } ?? "?"); panes are 1 to \(groups.count).")
        }
        return groups[number - 1]
    }

    private func find(_ value: Any?, pane: Any?, in router: AppRouter) throws -> (group: PaneGroup, tab: WorkspaceTab) {
        guard let wanted = (value as? String)?.lowercased(), !wanted.isEmpty else { throw ToolError("Give a tab name.") }
        let groups = try pane.map { [try group($0, in: router)] } ?? router.groups
        for group in groups {
            if let tab = group.tabs.first(where: { name(of: $0).lowercased() == wanted }) { return (group, tab) }
        }
        throw ToolError("No open tab named \(wanted). Call get_layout to see what is open.")
    }

    // MARK: Data

    private func market(_ value: Any?, in router: AppRouter) throws -> HLMarket {
        guard let wanted = (value as? String)?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else { throw ToolError("Give a coin.") }
        let markets = router.directory.markets
        if let exact = markets[wanted] ?? markets[wanted.uppercased()] { return exact }
        if let loose = markets.values.first(where: { $0.name.lowercased() == wanted.lowercased() }) { return loose }
        throw ToolError(markets.isEmpty ? "Markets are still loading; try again." : "Hyperliquid has no perp named \(wanted). Use list_markets to search.")
    }

    private func markets(_ arguments: [String: Any], in router: AppRouter) -> [String: Any] {
        let query = (arguments["query"] as? String ?? "").lowercased()
        let ascending = arguments["ascending"] as? Bool ?? false
        let limit = min(max(Self.int(arguments["limit"]) ?? 20, 1), 250)
        let sort = arguments["sort_by"] as? String ?? "volume"
        func price(_ market: HLMarket) -> Double { router.directory.mids[market.name] ?? market.ctx.midPx ?? market.ctx.markPx }
        func key(_ market: HLMarket) -> Double {
            switch sort {
            case "change": market.dayChange
            case "funding": market.ctx.funding
            case "open_interest": market.ctx.openInterest * market.ctx.markPx
            case "price": price(market)
            default: market.ctx.dayNtlVlm
            }
        }
        var list = router.directory.markets.values.filter { query.isEmpty || $0.name.lowercased().contains(query) }
        if sort == "name" {
            list.sort { ascending ? $0.name < $1.name : $0.name > $1.name }
        } else {
            list.sort { ascending ? key($0) < key($1) : key($0) > key($1) }
        }
        return [
            "total_matching": list.count,
            "markets": list.prefix(limit).map { market -> [String: Any] in
                [
                    "coin": market.name, "price": price(market),
                    "change_24h_pct": (market.dayChange * 10_000).rounded() / 100,
                    "funding_hourly_pct": (market.ctx.funding * 1_000_000).rounded() / 10_000,
                    "volume_24h_usd": market.ctx.dayNtlVlm.rounded(),
                    "open_interest_usd": (market.ctx.openInterest * market.ctx.markPx).rounded(),
                    "max_leverage": market.maxLeverage,
                ]
            },
        ]
    }

    private func accounts(in router: AppRouter) async -> [String: Any] {
        let wallets = router.wallets
        for wallet in wallets.wallets { await wallets.refresh(wallet.id) }
        return ["wallets": wallets.wallets.map { wallet -> [String: Any] in
            var info: [String: Any] = ["name": wallet.name, "address": wallet.tradingAddress, "selected": wallet.id == wallets.selectedID]
            guard let account = wallets.accounts[wallet.id] else {
                info["error"] = wallets.accountErrors[wallet.id] ?? "not loaded"
                return info
            }
            info["perp_account_value_usd"] = account.accountValue
            info["perp_free_usd"] = account.withdrawable
            info["spot_balances"] = account.spot.map { ["coin": $0.coin, "amount": $0.total] }
            info["positions"] = account.positions.map { position -> [String: Any] in
                let mark = router.directory.mids[position.coin]
                var row: [String: Any] = [
                    "coin": position.coin, "side": position.size > 0 ? "long" : "short", "size": abs(position.size),
                    "entry": position.entryPrice, "leverage": position.leverage, "margin": position.isCross ? "cross" : "isolated",
                    "unrealized_pnl_usd": mark.map { ($0 - position.entryPrice) * position.size } ?? position.unrealizedPnl,
                ]
                if let mark { row["price"] = mark }
                if let liquidation = position.liquidationPrice { row["liquidation"] = liquidation }
                return row
            }
            info["open_orders"] = account.orders.map {
                ["coin": $0.coin, "side": $0.isBuy ? "buy" : "sell", "price": $0.price, "size": $0.size] as [String: Any]
            }
            return info
        }]
    }

    private func solanaInfo(_ stats: SolanaStats) -> [String: Any] {
        var info: [String: Any] = [
            "symbol": stats.token.symbol, "name": stats.token.name, "address": stats.token.address,
            "price_usd": stats.price, "change_24h_pct": (stats.change24 * 10_000).rounded() / 100,
            "volume_24h_usd": stats.volume24.rounded(), "liquidity_usd": stats.liquidity.rounded(), "market_cap_usd": stats.marketCap.rounded(),
        ]
        if let holders = stats.holders { info["holders"] = holders }
        return info
    }

    private func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
