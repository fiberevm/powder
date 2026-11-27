import AppKit
import CryptoKit
import Security
import SwiftUI

/// A newer build, as the website's update feed describes it.
struct UpdateInfo: Equatable, Sendable {
    let version: String
    let url: URL
    /// SHA-256 of the archive, hex.
    let sha256: String
    let notes: String
    let page: URL?
}

enum UpdateError: LocalizedError {
    case feed, download, checksum, unpack, signature(String), olderVersion, cannotReplace(String)

    var errorDescription: String? {
        switch self {
        case .feed: "The update feed could not be read."
        case .download: "The update could not be downloaded."
        case .checksum: "The download does not match its published checksum. It was discarded."
        case .unpack: "The download could not be unpacked."
        case let .signature(reason): "The download is not a genuine Powder build (\(reason)). It was discarded."
        case .olderVersion: "The download is not newer than this version. It was discarded."
        case let .cannotReplace(reason): reason
        }
    }
}

/// Version numbers compared part by part: 0.10.0 is newer than 0.9.3.
enum AppVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

/// What the app's code signature says, and whether another bundle carries the same publisher's.
enum CodeIdentity {
    /// The Apple team that signed the running app with a Developer ID, or nil for a development or unsigned build.
    static let ownTeam: String? = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        // Developer ID builds only: a development build must never replace itself with a release.
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Throws unless `bundle` is this app, signed with a Developer ID by `team`, intact, and notarized by Apple.
    static func verify(_ bundle: URL, team: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signature("it has no signature")
        }
        let identifier = Bundle.main.bundleIdentifier ?? "io.powder.app"
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError.signature("the check could not be set up")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var failure: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &failure) == errSecSuccess else {
            let reason = failure?.takeRetainedValue().localizedDescription ?? "its signature is not Powder's"
            throw UpdateError.signature(reason)
        }
    }
}

/// Finds, downloads, checks and installs new versions of Powder.
///
/// An update is only installed when the download matches the feed's checksum **and** is signed with the same
/// Developer ID as the running app, notarized by Apple, and a higher version. So the website alone cannot
/// push a build: without the publisher's signing key, nothing it serves will be installed.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading(UpdateInfo, fraction: Double)
        case verifying(UpdateInfo)
        /// Downloaded and verified; installed when the app restarts.
        case ready(UpdateInfo)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    /// Whether the update window is showing.
    @Published var isPresented = false
    @Published private(set) var lastChecked: Date?

    /// `POWDER_UPDATE_FEED` points a test run at another feed (a local file works). It changes where the app looks,
    /// not what it accepts: a download still has to carry the publisher's signature and notarization.
    nonisolated static let feed: URL = ProcessInfo.processInfo.environment["POWDER_UPDATE_FEED"].flatMap(URL.init)
        ?? URL(string: "https://fiberevm.github.io/powder/downloads/update.json")!
    nonisolated private static var isTestFeed: Bool { ProcessInfo.processInfo.environment["POWDER_UPDATE_FEED"] != nil }
    /// For rehearsing an update end to end without anyone at the keyboard: `install` downloads and swaps without asking;
    /// `swap` also leaves the new copy unopened. Only honoured together with a test feed.
    nonisolated private static var rehearsal: String? { isTestFeed ? ProcessInfo.processInfo.environment["POWDER_UPDATE_REHEARSAL"] : nil }
    static let interval: Duration = .seconds(3_600)
    private static let skippedKey = "update.skipped"

    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var staged: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Why this copy cannot update itself, or nil when it can.
    var blocker: String? {
        if Launch.profile != nil, !Self.isTestFeed { return "This is a measuring run." }
        guard CodeIdentity.ownTeam != nil else { return "This is a development build. Updates apply to downloaded releases." }
        let path = Bundle.main.bundleURL.path
        if path.contains("/AppTranslocation/") { return "Move Powder to the Applications folder first: macOS is running it from a read-only place." }
        if !FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) {
            return "Powder cannot write to the folder it is in. Move it to Applications, or download the new version from the website."
        }
        return nil
    }

    /// Checks shortly after launch, then every hour.
    func start() {
        guard timer == nil, blocker == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Looks for a newer version. Asked for by the user, the result is always shown; on the timer, only a new version is.
    func check(userInitiated: Bool) async {
        if userInitiated { isPresented = true }
        switch phase {
        case .downloading, .verifying, .ready, .checking: return
        default: break
        }
        if userInitiated, let blocker {
            phase = .failed(blocker)
            return
        }
        if userInitiated { phase = .checking }
        do {
            let info = try await Self.fetch()
            lastChecked = Date()
            guard let info, AppVersion.isNewer(info.version, than: AppVersion.current) else {
                phase = userInitiated ? .upToDate : .idle
                return
            }
            // A version the user chose to skip is not offered again unless they ask.
            if !userInitiated, defaults.string(forKey: Self.skippedKey) == info.version {
                phase = .idle
                return
            }
            phase = .available(info)
            isPresented = true
            if Self.rehearsal != nil { install(info) }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func skip(_ info: UpdateInfo) {
        defaults.set(info.version, forKey: Self.skippedKey)
        dismiss()
    }

    /// Hides the window. A download in progress carries on; a version on offer is offered again at the next check.
    func dismiss() {
        isPresented = false
        switch phase {
        case .upToDate, .failed, .available: phase = .idle
        default: break
        }
    }

    func install(_ info: UpdateInfo) {
        guard work == nil else { return }
        work = Task { [weak self] in
            await self?.download(info)
            self?.work = nil
        }
    }

    // MARK: Feed

    /// The newest build for this Mac's processor, or nil when the feed has none.
    nonisolated static func fetch() async throws -> UpdateInfo? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 || feed.isFileURL else { throw UpdateError.feed }
        return try parse(data)
    }

    nonisolated static func parse(_ data: Data) throws -> UpdateInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let version = root["version"] as? String else {
            throw UpdateError.feed
        }
        #if arch(arm64)
        let build = root["apple-silicon"] as? [String: Any]
        #else
        let build = root["intel"] as? [String: Any]
        #endif
        guard let build, let address = build["url"] as? String, let url = URL(string: address, relativeTo: feed)?.absoluteURL,
              url.scheme == "https" || (feed.isFileURL && url.isFileURL), let sha = build["sha256"] as? String, sha.count == 64 else { return nil }
        return UpdateInfo(
            version: version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")), url: url, sha256: sha.lowercased(),
            notes: (root["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            page: (root["page"] as? String).flatMap(URL.init)
        )
    }

    // MARK: Download and checks

    private func download(_ info: UpdateInfo) async {
        guard let team = CodeIdentity.ownTeam else {
            phase = .failed(blocker ?? "This copy cannot update itself.")
            return
        }
        phase = .downloading(info, fraction: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("powder-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let archive = folder.appendingPathComponent("Powder.zip")
            try await Self.fetch(info.url, to: archive) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.phase { self?.phase = .downloading(info, fraction: fraction) }
                }
            }
            phase = .verifying(info)
            let app = try await Task.detached(priority: .userInitiated) {
                try Self.unpackAndVerify(archive: archive, in: folder, info: info, team: team)
            }.value
            staged = app
            phase = .ready(info)
            isPresented = true
            if Self.rehearsal != nil { restartToInstall() }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            phase = .failed(error.localizedDescription)
            isPresented = true
        }
    }

    /// Downloads to `file`, reporting progress. Done by the system's download task, not read byte by byte:
    /// that took a minute for a few megabytes.
    nonisolated private static func fetch(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: file, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            if totalBytesExpectedToWrite > 0 { progress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temporary file is gone when this returns, so it is moved now.
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            guard status == 200 || (status == nil && downloadTask.originalRequest?.url?.isFileURL == true) else {
                failure = UpdateError.download
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error ?? failure {
                continuation?.resume(throwing: error)
            } else {
                progress(1)
                continuation?.resume()
            }
            continuation = nil
        }
    }

    /// Checksum, unpack, signature, version: in that order, and the app is only returned if every one passes.
    nonisolated private static func unpackAndVerify(archive: URL, in folder: URL, info: UpdateInfo, team: String) throws -> URL {
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256 else { throw UpdateError.checksum }

        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = unpacked.appendingPathComponent("Powder.app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.unpack }

        try CodeIdentity.verify(app, team: team)

        // What the bundle itself says its version is, not what the feed claimed: an old genuine build is refused.
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let version = plist?["CFBundleShortVersionString"] as? String, AppVersion.isNewer(version, than: AppVersion.current) else {
            throw UpdateError.olderVersion
        }
        return app
    }

    // MARK: Install

    /// Swaps the verified build in and reopens the app. The swap happens after this process has exited.
    func restartToInstall() {
        guard let staged, case .ready = phase else { return }
        let destination = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
        OLD="$DEST.previous"
        rm -rf "$OLD"
        if mv "$DEST" "$OLD" && mv "$NEW" "$DEST"; then rm -rf "$OLD"; else [ -d "$OLD" ] && [ ! -d "$DEST" ] && mv "$OLD" "$DEST"; fi
        rm -rf "$STAGE"
        [ -z "$STAY_CLOSED" ] && open "$DEST"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // The folder the download was unpacked in: two levels above the staged app.
        let stage = staged.deletingLastPathComponent().deletingLastPathComponent().path
        process.environment = [
            "DEST": destination, "NEW": staged.path, "STAGE": stage.contains("powder-update-") ? stage : "",
            "PATH": "/usr/bin:/bin", "STAY_CLOSED": Self.rehearsal == "swap" ? "1" : "",
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed("Powder could not restart itself: \(error.localizedDescription)")
        }
    }
}

// MARK: - Window

/// The update window, in the app's own style.
struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("UPDATE")
                    .font(Term.font(11, .bold))
                    .foregroundStyle(PowderPalette.graphite)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Term.accent)
                Text("POWDER \(AppVersion.current)").foregroundStyle(.secondary)
                Spacer()
                Button {
                    updater.dismiss()
                } label: {
                    Text("✕").foregroundStyle(.secondary).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .font(Term.font(10.5))
            .padding(.horizontal, 12)
            .frame(height: 32)
            TermRule()

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520)
        .background(Term.chrome)
        .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
        .overlay(alignment: .top) { Term.accent.frame(height: 2) }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .font(Term.font(11.5))
        .foregroundStyle(Term.foreground)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            title("Checking for updates…")

        case .upToDate:
            title("Powder is up to date")
            Text("Version \(AppVersion.current) is the newest. Powder checks again every hour.").foregroundStyle(.secondary)
            actions { TermButton("OK", kind: .primary) { updater.dismiss() } }

        case let .available(info):
            title("Powder \(info.version) is available")
            Text("You have \(AppVersion.current).").foregroundStyle(.secondary)
            notes(info)
            actions {
                TermButton("UPDATE NOW", kind: .primary) { updater.install(info) }
                TermButton("LATER") { updater.dismiss() }
                TermButton("SKIP THIS VERSION") { updater.skip(info) }
            }
            Text("The download is checked against Powder's signature before anything is replaced.")
                .font(Term.font(10.5))
                .foregroundStyle(.secondary)

        case let .downloading(info, fraction):
            title("Downloading Powder \(info.version)")
            progress(fraction)
            Text("\(Int((fraction * 100).rounded()))%  ·  you can keep trading").foregroundStyle(.secondary)

        case let .verifying(info):
            title("Checking Powder \(info.version)")
            progress(1)
            Text("Verifying the checksum, the signature and Apple's notarization…").foregroundStyle(.secondary)

        case let .ready(info):
            title("Powder \(info.version) is ready")
            Text("It was downloaded and verified. Restarting takes a few seconds; your layout and wallets are kept. Open positions and resting orders are on the exchange and are not affected.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions {
                TermButton("RESTART NOW", kind: .primary) { updater.restartToInstall() }
                TermButton("ON NEXT LAUNCH") { updater.isPresented = false }
            }

        case let .failed(message):
            title("Update not installed")
            Text(message)
                .foregroundStyle(PowderPalette.riskCoral)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            actions {
                TermButton("OK", kind: .primary) { updater.dismiss() }
                TermButton("OPEN THE DOWNLOAD PAGE") {
                    if let url = URL(string: "https://fiberevm.github.io/powder/#download") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Term.font(15, .bold))
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }.padding(.top, 2)
    }

    private func progress(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Term.rule)
                Rectangle().fill(Term.accent).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private func notes(_ info: UpdateInfo) -> some View {
        if !info.notes.isEmpty {
            ScrollView {
                Text(info.notes)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: 180)
            .background(Term.background)
            .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
        }
    }
}
