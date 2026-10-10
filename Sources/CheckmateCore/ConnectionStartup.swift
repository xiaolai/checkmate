import Foundation

/// One startup attempt. Dependencies keep automation away from accounts and audio.
@MainActor public final class ConnectionStartup {
    private let settings: () -> AppSettings
    private let check: () async -> String?
    private let connectVoice: (String) -> Void
    private let startMCP: () throws -> Void
    private let stillCurrent: () -> Bool
    private let silent: Bool
    private var started = false
    private var task: Task<Void, Never>?

    public init(settings: @escaping () -> AppSettings,
                check: @escaping () async -> String?,
                connectVoice: @escaping (String) -> Void,
                startMCP: @escaping () throws -> Void,
                stillCurrent: @escaping () -> Bool,
                silent: Bool = NativePolicy.silent) {
        self.settings = settings; self.check = check
        self.connectVoice = connectVoice; self.startMCP = startMCP
        self.stillCurrent = stillCurrent; self.silent = silent
    }

    public func start() {
        guard !started, !silent else { return }
        started = true
        task = Task { [weak self] in
            guard let self else { return }
            let authorization = await check()
            guard !Task.isCancelled, stillCurrent() else { return }
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

    public func cancel() { task?.cancel(); task = nil }
}
