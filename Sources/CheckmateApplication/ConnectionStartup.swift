import CheckmateDomain
import CheckmateRules
import CheckmateContent
import CheckmateSupport
import CheckmateAssets
import Foundation

/// One startup attempt. Dependencies keep automation away from accounts and audio. An attempt that finds the app
/// hidden or suspended waits, and `resumeIfDeferred()` (on unhide) runs it again; one overtaken by the learner or by
/// shutdown (`stillCurrent` false) ends.
@MainActor public final class ConnectionStartup {
    private let settings: () -> AppSettings
    private let check: () async -> String?
    private let connectVoice: (String) -> Void
    private let startMCP: () throws -> Void
    private let stillCurrent: () -> Bool
    private let visible: () -> Bool
    private let silent: Bool
    private var started = false
    public private(set) var deferred = false
    private var task: Task<Void, Never>?

    public init(settings: @escaping () -> AppSettings,
                check: @escaping () async -> String?,
                connectVoice: @escaping (String) -> Void,
                startMCP: @escaping () throws -> Void,
                stillCurrent: @escaping () -> Bool,
                visible: @escaping () -> Bool = { true },
                silent: Bool = NativePolicy.silent) {
        self.settings = settings; self.check = check
        self.connectVoice = connectVoice; self.startMCP = startMCP
        self.stillCurrent = stillCurrent; self.visible = visible; self.silent = silent
    }

    public func start() {
        guard !started, !silent else { return }
        started = true
        task = Task { [weak self] in
            guard let self else { return }
            let authorization = await check()
            guard !Task.isCancelled, stillCurrent() else { return }
            guard visible() else { deferred = true; task = nil; return }
            // Re-read preferences after authorization; a learner may have opted out.
            let preferences = settings()
            if preferences.voiceAutoConnect, let authorization {
                connectVoice(authorization)
            }
            if preferences.companionAutoStart {
                // A voice authorization failure does not prevent local MCP access.
                try? startMCP()
            }
            task = nil
        }
    }

    /// Runs a deferred attempt again (with a fresh availability check) once the app is shown.
    public func resumeIfDeferred() { guard deferred, task == nil else { return }; deferred = false; started = false; start() }

    public func cancel() { task?.cancel(); task = nil; deferred = false }
}
