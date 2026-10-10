import XCTest
@testable import CheckmateCore

@MainActor final class ConnectionStartupTests: XCTestCase {
    private func settle() async { for _ in 0..<12 { await Task.yield() } }

    func testDefaultsAndPersistedOptOuts() throws {
        XCTAssertTrue(AppSettings().voiceAutoConnect)
        XCTAssertTrue(AppSettings(raw: [:]).companionAutoStart)
        let settings = AppSettings(raw: ["voiceAutoConnect": false, "companionAutoStart": false])
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.voiceAutoConnect)
        XCTAssertFalse(restored.companionAutoStart)
        XCTAssertTrue(AppSettings(raw: ["voiceAutoConnect": 0, "companionAutoStart": "false"]).voiceAutoConnect)
    }

    func testAuthorizedStartupReusesCredentialAndRunsOnlyOnce() async {
        var events: [String] = []
        let startup = ConnectionStartup(settings: { AppSettings() }, check: {
            events.append("check"); return "test-session"
        }, connectVoice: { credential in
            XCTAssertEqual(credential, "test-session"); events.append("voice")
        }, startMCP: { events.append("mcp") }, stillCurrent: { true }, silent: false)
        startup.start(); startup.start(); await settle()
        XCTAssertEqual(events, ["check", "voice", "mcp"])
    }

    func testIndependentTogglesAndFailedVoiceAuthorization() async {
        for voice in [false, true] {
            for mcp in [false, true] {
                for available in [false, true] {
                    var settings = AppSettings(); settings.voiceAutoConnect = voice; settings.companionAutoStart = mcp
                    var voiceStarts = 0, mcpStarts = 0
                    let startup = ConnectionStartup(settings: { settings }, check: { available ? "test-session" : nil },
                        connectVoice: { _ in voiceStarts += 1 }, startMCP: { mcpStarts += 1 },
                        stillCurrent: { true }, silent: false)
                    startup.start(); await settle()
                    XCTAssertEqual(voiceStarts, voice && available ? 1 : 0)
                    XCTAssertEqual(mcpStarts, mcp ? 1 : 0)
                }
            }
        }
    }

    func testOptOutWhileCheckPendingPreventsAutomaticConnection() async {
        var settings = AppSettings(), started = false, connections = 0
        var continuation: CheckedContinuation<String?, Never>?
        let startup = ConnectionStartup(settings: { settings }, check: {
            started = true; return await withCheckedContinuation { continuation = $0 }
        }, connectVoice: { _ in connections += 1 }, startMCP: { connections += 1 },
            stillCurrent: { true }, silent: false)
        startup.start(); await settle(); XCTAssertTrue(started)
        settings.voiceAutoConnect = false; settings.companionAutoStart = false
        continuation?.resume(returning: "test-session"); await settle()
        XCTAssertEqual(connections, 0)
    }

    func testCancelledOrSupersededCheckDoesNotUndoManualActions() async {
        for cancel in [false, true] {
            var current = true, connections = 0
            var continuation: CheckedContinuation<String?, Never>?
            let startup = ConnectionStartup(settings: { AppSettings() }, check: {
                await withCheckedContinuation { continuation = $0 }
            }, connectVoice: { _ in connections += 1 }, startMCP: { connections += 1 },
                stillCurrent: { current }, silent: false)
            startup.start(); await settle()
            if cancel { startup.cancel() } else { current = false }
            continuation?.resume(returning: "test-session"); await settle()
            XCTAssertEqual(connections, 0)
        }
    }

    func testAutomationNeverChecksAccountsOrStartsConnections() async throws {
        var effects = 0
        let startup = ConnectionStartup(settings: { AppSettings() }, check: { effects += 1; return "test-session" },
            connectVoice: { _ in effects += 1 }, startMCP: { effects += 1 }, stillCurrent: { true }, silent: true)
        startup.start(); await settle(); XCTAssertEqual(effects, 0)
        let session = try GameSession(engine: nil), voice = try VoiceCoach(session: session)
        let authorization = await voice.checkAvailability().value
        XCTAssertNil(authorization)
        voice.connect(authorizedSecret: "test-session")
        XCTAssertNil(session.voiceLease); XCTAssertFalse(voice.connecting)
        XCTAssertFalse(voice.audio.capturing)
    }

    func testMCPFailureDoesNotStopVoiceOrRetry() async {
        var voices = 0, attempts = 0
        let startup = ConnectionStartup(settings: { AppSettings() }, check: { "test-session" },
            connectVoice: { _ in voices += 1 }, startMCP: { attempts += 1; throw CheckmateError.unavailable("fixture") },
            stillCurrent: { true }, silent: false)
        startup.start(); await settle(); startup.start(); await settle()
        XCTAssertEqual(voices, 1); XCTAssertEqual(attempts, 1)
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
        let rejected = try await read()
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "SESSION_IN_USE")
        XCTAssertEqual(session.voiceLease, voiceLease)
        broker.suspend(true); broker.suspend(false)
        XCTAssertFalse(session.companionEnabled)
        session.closeVoice()
        let accepted = try await read()
        XCTAssertNil(accepted["error"])
        XCTAssertTrue(broker.connected); XCTAssertTrue(session.companionEnabled)
        XCTAssertThrowsError(try session.openVoice())
        broker.release()
        XCTAssertFalse(session.companionEnabled)
        _ = try session.openVoice()
        broker.disable()
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
