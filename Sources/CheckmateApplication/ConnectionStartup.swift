import CheckmateDomain
import CheckmateSupport
import Foundation

/// One startup attempt. Dependencies keep automation away from accounts and audio. An attempt that finds the app
/// hidden or suspended waits, and `resumeIfDeferred()` (on unhide) runs it again; one overtaken by the learner or by
/// shutdown (`stillCurrent` false) ends. `Authorization` is what a successful check hands to `connectVoice` (the app's
/// realtime secret); startup only passes it on.
@MainActor public final class ConnectionStartup<Authorization> {
    private let settings: () -> AppSettings
    private let check: () async -> Authorization?
    private let connectVoice: (Authorization) -> Void
    private let startMCP: () throws -> Void
    private let codexSetUp: () -> Bool
    private let stillCurrent: () -> Bool
    private let visible: () -> Bool
    private let silent: Bool
    private var started = false
    public private(set) var deferred = false
    private var task: Task<Void, Never>?

    public init(settings: @escaping () -> AppSettings,
                check: @escaping () async -> Authorization?,
                connectVoice: @escaping (Authorization) -> Void,
                startMCP: @escaping () throws -> Void,
                codexSetUp: @escaping () -> Bool,
                stillCurrent: @escaping () -> Bool,
                visible: @escaping () -> Bool = { true },
                silent: Bool = NativePolicy.silent) {
        self.settings = settings; self.check = check
        self.connectVoice = connectVoice; self.startMCP = startMCP; self.codexSetUp = codexSetUp
        self.stillCurrent = stillCurrent; self.visible = visible; self.silent = silent
    }

    public func start() {
        guard !started, !silent else { return }
        started = true
        task = Task { [weak self] in
            guard let self else { return }
            // Local MCP needs no account, so it starts at once instead of waiting behind the voice check.
            startMCPIfWanted()
            // The check reads the Codex sign-in and opens a provider session; only voice needs it, so a learner who
            // has not agreed to voice, or opted out of connecting it on launch, never sends their credential.
            let authorization = voiceWanted ? await check() : nil
            guard !Task.isCancelled, stillCurrent() else { return }
            guard visible() else { deferred = true; task = nil; return }
            // Re-read preferences after authorization; a learner may have opted out.
            if voiceWanted, let authorization {
                connectVoice(authorization)
            }
            // Started now if the app was hidden at first; a voice authorization failure never prevents it.
            startMCPIfWanted()
            task = nil
        }
    }

    /// Voice connects on launch only with the learner's consent and their choice to connect then.
    private var voiceWanted: Bool { let settings = settings(); return settings.voiceConsent && settings.voiceAutoConnect }

    /// Once per launch, only while visible, and only for a Codex that Set up Codex registered: a failed start is
    /// logged and not retried. The broker shows its own failure in Settings ▸ Connections.
    private var mcpAttempted = false
    private func startMCPIfWanted() {
        guard !mcpAttempted, settings().companionAutoStart, visible(), stillCurrent(), codexSetUp() else { return }
        mcpAttempted = true
        do { try startMCP() } catch { NativeLog.companion.error("Chess MCP did not start on launch: \(String(describing: error), privacy: .public)") }
    }

    /// Runs a deferred attempt again (with a fresh availability check) once the app is shown.
    public func resumeIfDeferred() { guard deferred, task == nil else { return }; deferred = false; started = false; start() }

    public func cancel() { task?.cancel(); task = nil; deferred = false }
}
