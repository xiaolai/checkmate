import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform
import RealtimeConnection


@MainActor final class ConnectionStartupTests: XCTestCase {
    private func settle() async { for _ in 0..<12 { await Task.yield() } }

    /// Settings of a learner who agreed to voice and asked it to connect on launch.
    private func consented() -> AppSettings { var settings = AppSettings(); settings.voiceConsent = true; settings.voiceAutoConnect = true; return settings }

    func testDefaultsAndPersistedOptOuts() throws {
        XCTAssertTrue(AppSettings(raw: [:]).companionAutoStart)
        let settings = AppSettings(raw: ["voiceAutoConnect": false, "companionAutoStart": false])
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.voiceAutoConnect)
        XCTAssertFalse(restored.companionAutoStart)
        XCTAssertFalse(AppSettings(raw: ["voiceAutoConnect": 0, "companionAutoStart": "false"]).voiceAutoConnect, "an invalid value reads as a new setting")
    }

    /// V-1: voice is opt-in. A new install never connects on launch; a learner whose saved settings predate consent and
    /// had connecting at launch on keeps connecting at launch, not just the stored value.
    func testVoiceIsOptInForNewInstallsAndKeptForExistingOnes() async throws {
        XCTAssertFalse(AppSettings().voiceAutoConnect); XCTAssertFalse(AppSettings(raw: [:]).voiceAutoConnect)
        XCTAssertFalse(AppSettings().voiceConsent); XCTAssertFalse(AppSettings(raw: [:]).voiceConsent)
        // A state file from before consent existed: connecting at launch on, no `voiceConsent`, and a newer field.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = StateStore(directory: directory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ApplicationState())) as? [String: Any])
        var raw = try XCTUnwrap(object["settings"] as? [String: Any]); raw.removeValue(forKey: "voiceConsent"); raw["voiceAutoConnect"] = true; raw["futureSetting"] = "x"
        object["settings"] = raw; try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        let legacy = try store.load().settings
        XCTAssertTrue(legacy.voiceAutoConnect, "a stored choice is kept"); XCTAssertTrue(legacy.voiceConsent, "an existing install with it on keeps its behaviour")
        XCTAssertFalse(AppSettings(raw: ["voiceAutoConnect": false]).voiceConsent, "an older install that had it off still asks")
        XCTAssertFalse(AppSettings(raw: ["voiceAutoConnect": true, "voiceConsent": false]).voiceConsent, "a saved answer is never overridden")
        try store.save(try store.load())
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])["settings"] as? [String: Any]
        XCTAssertEqual(written?["voiceConsent"] as? Bool, true, "consent is saved under its own key")
        XCTAssertEqual(written?["futureSetting"] as? String, "x", "an unknown field survives the round trip")
        for (settings, connects) in [(legacy, true), (AppSettings(), false), (try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)), false)] {
            var checks = 0, voices = 0
            let startup = ConnectionStartup(settings: { settings }, check: { checks += 1; return "test-session" },
                connectVoice: { _ in voices += 1 }, startMCP: {}, codexSetUp: { true }, stillCurrent: { true }, silent: false)
            startup.start(); await settle()
            XCTAssertEqual(checks, connects ? 1 : 0); XCTAssertEqual(voices, connects ? 1 : 0, "launch behaviour for \(settings.voiceAutoConnect)")
        }
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(consented()))
        XCTAssertTrue(restored.voiceConsent); XCTAssertTrue(restored.voiceAutoConnect)
    }

    /// V-1: connecting on launch needs the learner's consent as well as the setting; without it the Codex sign-in is
    /// never read.
    func testAutomaticVoiceNeverConnectsWithoutConsent() async {
        for consent in [false, true] {
            var settings = AppSettings(raw: ["voiceAutoConnect": true]); settings.voiceConsent = consent
            var checks = 0, voices = 0
            let startup = ConnectionStartup(settings: { settings }, check: { checks += 1; return "test-session" },
                connectVoice: { _ in voices += 1 }, startMCP: {}, codexSetUp: { true }, stillCurrent: { true }, silent: false)
            startup.start(); await settle()
            XCTAssertEqual(checks, consent ? 1 : 0); XCTAssertEqual(voices, consent ? 1 : 0)
        }
    }

    func testAuthorizedStartupReusesCredentialAndRunsOnlyOnce() async {
        var events: [String] = []
        let startup = ConnectionStartup(settings: { self.consented() }, check: {
            events.append("check"); return "test-session"
        }, connectVoice: { credential in
            XCTAssertEqual(credential, "test-session"); events.append("voice")
        }, startMCP: { events.append("mcp") }, codexSetUp: { true }, stillCurrent: { true }, silent: false)
        startup.start(); startup.start(); await settle()
        XCTAssertEqual(events, ["mcp", "check", "voice"], "local MCP never waits for the voice check")
    }

    /// Hidden during the check (Cmd-H, or launched hidden): the attempt waits and runs when the app is shown.
    func testHiddenStartupWaitsAndResumesWhenShown() async {
        var events: [String] = [], hidden = true
        let startup = ConnectionStartup(settings: { self.consented() }, check: { events.append("check"); return "test-session" },
            connectVoice: { _ in events.append("voice") }, startMCP: { events.append("mcp") }, codexSetUp: { true }, stillCurrent: { true }, visible: { !hidden }, silent: false)
        startup.start(); await settle()
        XCTAssertEqual(events, ["check"]); XCTAssertTrue(startup.deferred)
        startup.start(); await settle(); XCTAssertEqual(events, ["check"], "A deferred attempt is resumed, not restarted by start()")
        hidden = false; startup.resumeIfDeferred(); await settle()
        XCTAssertEqual(events, ["check", "mcp", "check", "voice"]); XCTAssertFalse(startup.deferred)
        startup.resumeIfDeferred(); await settle(); XCTAssertEqual(events.count, 4, "A finished attempt never runs again")
    }

    func testIndependentTogglesAndFailedVoiceAuthorization() async {
        for voice in [false, true] {
            for mcp in [false, true] {
                for available in [false, true] {
                    var settings = consented(); settings.voiceAutoConnect = voice; settings.companionAutoStart = mcp
                    var voiceStarts = 0, mcpStarts = 0, checks = 0
                    let startup = ConnectionStartup(settings: { settings }, check: { checks += 1; return available ? "test-session" : nil },
                        connectVoice: { _ in voiceStarts += 1 }, startMCP: { mcpStarts += 1 },
                        codexSetUp: { true }, stillCurrent: { true }, silent: false)
                    startup.start(); await settle()
                    XCTAssertEqual(voiceStarts, voice && available ? 1 : 0)
                    XCTAssertEqual(mcpStarts, mcp ? 1 : 0)
                    XCTAssertEqual(checks, voice ? 1 : 0, "Opted out of voice on launch, the Codex sign-in is never read")
                }
            }
        }
    }

    /// Opting out of voice while its check is pending prevents the connection; local MCP had already started without
    /// waiting for the check.
    func testOptOutWhileCheckPendingPreventsAutomaticConnection() async {
        var settings = consented(), started = false, voices = 0, mcp = 0
        var continuation: CheckedContinuation<String?, Never>?
        let startup = ConnectionStartup(settings: { settings }, check: {
            started = true; return await withCheckedContinuation { continuation = $0 }
        }, connectVoice: { _ in voices += 1 }, startMCP: { mcp += 1 },
            codexSetUp: { true }, stillCurrent: { true }, silent: false)
        startup.start(); await settle(); XCTAssertTrue(started)
        XCTAssertEqual(mcp, 1, "MCP started while the voice check was still pending")
        settings.voiceAutoConnect = false; settings.companionAutoStart = false
        continuation?.resume(returning: "test-session"); await settle()
        XCTAssertEqual(voices, 0); XCTAssertEqual(mcp, 1)
    }

    func testCancelledOrSupersededCheckDoesNotUndoManualActions() async {
        for cancel in [false, true] {
            var current = true, voices = 0, mcp = 0
            var continuation: CheckedContinuation<String?, Never>?
            let startup = ConnectionStartup(settings: { self.consented() }, check: {
                await withCheckedContinuation { continuation = $0 }
            }, connectVoice: { _ in voices += 1 }, startMCP: { mcp += 1 },
                codexSetUp: { true }, stillCurrent: { current }, silent: false)
            startup.start(); await settle()
            XCTAssertEqual(mcp, 1, "MCP started before the check")
            if cancel { startup.cancel() } else { current = false }
            continuation?.resume(returning: "test-session"); await settle()
            XCTAssertEqual(voices, 0); XCTAssertEqual(mcp, 1, "no second MCP start")
        }
    }

    func testAutomationNeverChecksAccountsOrStartsConnections() async throws {
        var effects = 0
        let startup = ConnectionStartup(settings: { self.consented() }, check: { effects += 1; return "test-session" },
            connectVoice: { _ in effects += 1 }, startMCP: { effects += 1 }, codexSetUp: { true }, stillCurrent: { true }, silent: true)
        startup.start(); await settle(); XCTAssertEqual(effects, 0)
        // Agreed, so it is automation that stops the check and the connection, not the missing consent.
        let session = try GameSession(engine: nil), voice = try VoiceCoach(session: session); session.state.settings.voiceConsent = true
        let authorization = await voice.checkAvailability().value
        XCTAssertNil(authorization)
        voice.connect(authorizedSecret: ClientSecret(bearer: "test-session", expiresAt: Date()))
        XCTAssertNil(session.voiceLease); XCTAssertFalse(voice.connecting)
        XCTAssertFalse(voice.audio.capturing)
    }

    /// V-12: chess MCP starts on launch only once Set up Codex registered Checkmate; without it nothing listens.
    func testMCPStartsOnLaunchOnlyWhenCodexIsSetUp() async {
        for setUp in [false, true] {
            var mcp = 0
            let startup = ConnectionStartup<String>(settings: { AppSettings() }, check: { String?.none }, connectVoice: { _ in },
                startMCP: { mcp += 1 }, codexSetUp: { setUp }, stillCurrent: { true }, silent: false)
            startup.start(); await settle()
            XCTAssertEqual(mcp, setUp ? 1 : 0)
        }
    }

    func testMCPFailureDoesNotStopVoiceOrRetry() async {
        var voices = 0, attempts = 0
        let startup = ConnectionStartup(settings: { self.consented() }, check: { "test-session" },
            connectVoice: { _ in voices += 1 }, startMCP: { attempts += 1; throw CheckmateError.unavailable("fixture") },
            codexSetUp: { true }, stillCurrent: { true }, silent: false)
        startup.start(); await settle(); startup.start(); await settle()
        XCTAssertEqual(voices, 1); XCTAssertEqual(attempts, 1)
    }

    /// A launch start of MCP that fails, at once or once its listener is up, leaves the broker's own reason, which
    /// Settings ▸ Connections shows (`companion.error`); startup only logs it and does not retry.
    func testAFailedMCPStartOnLaunchIsShownByTheBroker() async throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocked); defer { try? FileManager.default.removeItem(at: blocked) }
        // The discovery directory is a file: the listener comes up, then publishing its connection file fails.
        let session = try GameSession(engine: nil), broker = try CompanionBroker(session: session, directory: blocked)
        defer { broker.disable() }
        let startup = ConnectionStartup(settings: { AppSettings() }, check: { String?.none }, connectVoice: { _ in },
            startMCP: { try broker.enable(role: "coach", standby: true) }, codexSetUp: { true }, stillCurrent: { true }, silent: false)
        startup.start()
        for _ in 0..<200 where broker.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(broker.problem, .discoveryFailed); XCTAssertEqual(broker.error, CompanionProblem.discoveryFailed.message); XCTAssertFalse(broker.enabled)
        // A start refused at once because the voice coach holds the session says so, and what to do.
        let held = try GameSession(engine: nil), refused = try CompanionBroker(session: held, directory: blocked)
        defer { refused.disable() }
        _ = try held.openVoice()
        let immediate = ConnectionStartup(settings: { AppSettings() }, check: { String?.none }, connectVoice: { _ in },
            startMCP: { try refused.enable(role: "coach") }, codexSetUp: { true }, stillCurrent: { true }, silent: false)
        immediate.start(); await settle()
        XCTAssertEqual(refused.problem, .voiceConnected); XCTAssertEqual(refused.error, CompanionProblem.voiceConnected.message); XCTAssertFalse(refused.enabled)
    }
}

@MainActor final class BrokerStandbyTests: XCTestCase {
    func testStandbyDefersControlUntilVoiceDisconnects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = try GameSession(engine: nil), broker = try CompanionBroker(session: session, directory: directory)
        defer { broker.disable(); try? FileManager.default.removeItem(at: directory) }
        let voiceLease = try session.openVoice()
        try broker.enable(role: "coach", standby: true)
        XCTAssertEqual(session.voiceLease, voiceLease)
        XCTAssertFalse(session.companionEnabled)
        let file = directory.appendingPathComponent("connection.json")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let discovery = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let client = UUID().uuidString
        func read() async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: (discovery["url"] as! String) + "/rpc")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + (discovery["token"] as! String), forHTTPHeaderField: "Authorization")
            request.setValue(client, forHTTPHeaderField: "X-Checkmate-Client")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": "get_session", "args": [:]])
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        XCTAssertTrue(broker.enabled); XCTAssertFalse(broker.connected)
        for _ in 0..<100 where broker.state != .waitingForVoice { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(broker.state, .waitingForVoice, "Settings says Codex waits for the voice coach")
        let rejected = try await read()
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "SESSION_IN_USE")
        XCTAssertEqual(session.voiceLease, voiceLease)
        broker.suspend(true); XCTAssertEqual(broker.state, .paused)
        broker.suspend(false); XCTAssertEqual(broker.state, .waitingForVoice, "showing the app again still waits for voice")
        XCTAssertFalse(session.companionEnabled)
        session.closeVoice()
        let accepted = try await read()
        XCTAssertNil(accepted["error"])
        XCTAssertTrue(broker.connected); XCTAssertTrue(session.companionEnabled); XCTAssertEqual(broker.state, .connected)
        XCTAssertThrowsError(try session.openVoice())
        broker.release()
        XCTAssertFalse(session.companionEnabled); XCTAssertEqual(broker.state, .waiting); XCTAssertEqual(broker.status, CompanionState.waiting.text)
        _ = try session.openVoice()
        broker.disable(); XCTAssertEqual(broker.state, .off)
        XCTAssertNotNil(session.voiceLease)
        session.closeVoice()
    }

    func testStandbyOpponentDoesNotReserveBlackBeforeAClientClaims() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = try GameSession(engine: nil), broker = try CompanionBroker(session: session, directory: directory)
        defer { broker.disable(); try? FileManager.default.removeItem(at: directory) }
        try broker.enable(role: "opponent", standby: true)
        XCTAssertFalse(session.companionEnabled)
        _ = try session.openVoice()
        session.closeVoice()
    }
}
