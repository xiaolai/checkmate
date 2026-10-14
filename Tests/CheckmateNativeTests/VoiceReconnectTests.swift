import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// D2: voice the learner had connected comes back when Practice is shown again; voice that was off stays off.
/// The live connection is replaced by a counter: no network, no audio.
@MainActor final class VoiceReconnectTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func model()throws -> (NativeModel,() -> Int) {
        let model=try NativeModel();var reconnects=0;model.reconnectVoice={reconnects+=1};return (model,{reconnects})
    }
    private func connectVoice(_ model:NativeModel)throws {_ = try model.session.openVoice();model.voice.receive(["type":"session.updated"]);XCTAssertTrue(model.voice.connected,"fixture: voice is connected")}
    private func settle()async throws {try await Task.sleep(for:.milliseconds(50))}

    func testConnectedVoiceReturnsWithPractice()async throws {
        let (model,reconnects)=try model();defer{model.shutdown()}
        try connectVoice(model);model.lesson(1);try await settle()
        XCTAssertFalse(model.voice.connected,"a lesson disconnects voice");XCTAssertEqual(reconnects(),0)
        model.practice();try await settle()
        XCTAssertEqual(reconnects(),1,"voice reconnects when Practice is shown again");XCTAssertFalse(model.voiceResumeIntent)
        model.lesson(1);model.practice();try await settle();XCTAssertEqual(reconnects(),1,"the intent is used once")
    }
    func testVoiceThatWasOffStaysOff()async throws {
        let (model,reconnects)=try model();defer{model.shutdown()}
        try connectVoice(model);model.voice.disconnect()
        model.lesson(1);model.practice();try await settle()
        XCTAssertEqual(reconnects(),0,"an explicit disconnect is respected")
    }
    func testVoiceReturnsWhenTheAppComesBack()async throws {
        let (model,reconnects)=try model();defer{model.shutdown()}
        try connectVoice(model);model.setAway(true);XCTAssertFalse(model.voice.connected)
        model.setAway(false);XCTAssertEqual(reconnects(),1)
    }
    /// A companion that took the session while voice was away cancels the return, even if it has let go since.
    func testATakeoverThatEndedStillCancelsTheReturn()async throws {
        let (model,reconnects)=try model();defer{model.shutdown()}
        try connectVoice(model);model.lesson(1)
        // Taken and released with no main-loop turn in between: the takeover is still seen.
        model.session.setConnection(enabled:true,role:"coach",lease:"companion")
        model.session.setConnection(enabled:false,role:"coach");model.practice();try await settle()
        XCTAssertEqual(reconnects(),0)
    }
    /// Returning while connecting is blocked (a lesson recording) keeps the intent; it reconnects once unblocked.
    func testABlockedReturnWaitsUntilUnblocked()async throws {
        let (model,reconnects)=try model();defer{model.shutdown()}
        var blocked=true;model.voice.connectionBlocked={blocked}
        try connectVoice(model);model.lesson(1);model.practice();try await settle()
        XCTAssertEqual(reconnects(),0);XCTAssertTrue(model.voiceResumeIntent,"the intent was spent on a refused attempt")
        blocked=false;model.resumeVoiceIfIntended();XCTAssertEqual(reconnects(),1)
    }
    func testACompanionTakingTheSessionCancelsTheReturn()async throws {
        let (model,reconnects)=try model();defer{model.shutdown()}
        try connectVoice(model);model.lesson(1)
        model.session.setConnection(enabled:true,role:"coach",lease:"companion")
        model.practice();try await settle()
        XCTAssertEqual(reconnects(),0);XCTAssertFalse(model.voiceResumeIntent)
    }
}
