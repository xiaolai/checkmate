import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform
import RealtimeConnection
import CodexAuth

/// V-6, V-7, V-22, V-5: every voice or Codex problem is one plain cause with one action, the coach's model is kept for a
/// day across launches, and voice without Codex is explained instead of failing. Silent: no sign-in, socket or audio.
@MainActor final class VoiceFailureTests:XCTestCase {
    /// Every failure has a cause in plain words and at most one action; no two causes read alike. A failure that lasts
    /// as long as the learner stays where they are (a network game, a screen the coach does not join) offers no retry,
    /// which could only fail again: it offers nothing and its cause says when the coach becomes available.
    func testEveryFailureHasOneCauseAndOneAction() {
        let jargon=["MCP","model access","ply","half-move","Recheck","HTTP","token","realtime","Realtime","method"]
        for failure in VoiceFailure.allCases {
            XCTAssertFalse(failure.cause.isEmpty,"\(failure)");XCTAssertTrue(failure.cause.hasSuffix("."),"\(failure): \(failure.cause)")
            for word in jargon {XCTAssertFalse(failure.cause.contains(word),"\(failure) says \(word): \(failure.cause)")}
            XCTAssertEqual(userFacingMessage(failure,fallback:""),failure.cause)
        }
        XCTAssertEqual(Set(VoiceFailure.allCases.map(\.cause)).count,VoiceFailure.allCases.count,"each cause has its own words")
        XCTAssertEqual(Set(VoiceFailure.allCases.compactMap(\.action)),Set(VoiceAction.allCases),"every action is offered by some failure")
        let lastsHere:[VoiceFailure]=[.networkGame,.notHere]
        for failure in lastsHere {XCTAssertNil(failure.action,"\(failure) offers an action that cannot work here")}
        XCTAssertTrue(VoiceFailure.networkGame.cause.contains("once the game ends"),VoiceFailure.networkGame.cause)
        XCTAssertTrue(VoiceFailure.notHere.cause.contains("Return to"),VoiceFailure.notHere.cause)
        for failure in VoiceFailure.allCases where failure.action==nil {XCTAssertTrue(lastsHere.contains(failure),"\(failure) has no action")}
        for action in VoiceAction.allCases {XCTAssertEqual(action.title.split(separator:" ").filter{$0.first?.isLowercase==true},[],"\(action.title) is in title case")}
        XCTAssertEqual(VoiceFailure.microphoneDenied.action,.openMicrophoneSettings);XCTAssertEqual(VoiceFailure.noCodex.action,.getCodex)
        XCTAssertEqual(VoiceFailure.signInExpired.action,.signIn);XCTAssertEqual(VoiceFailure.codexNotSetUp.action,.setUpCodex);XCTAssertEqual(VoiceFailure.offline.action,.tryAgain)
    }
    /// L-32: an aged-out sign-in (Codex could not renew it, or the voice service refused it) says what renews it, as
    /// lesson translation does, rather than only that it failed.
    func testAStaleSignInSaysHowToRenewIt() {
        for failure in [VoiceFailure.signInExpired,.signInRejected] {
            XCTAssertTrue(failure.cause.contains("Open Codex and sign in again with your ChatGPT account"),"\(failure): \(failure.cause)")
            XCTAssertEqual(failure.action,.signIn)
        }
        XCTAssertEqual(VoiceFailure.from(CodexAuthError(.expired)),.signInExpired,"a refresh that did not renew the sign-in")
        XCTAssertEqual(VoiceFailure.from(RealtimeError(.authExpired)),.signInRejected,"a token the voice service refused after a refresh")
    }
    /// Unknown errors are one failure; the error's own words stay in the log.
    func testAnyErrorMapsToOneFailure() {
        XCTAssertEqual(VoiceFailure.from(VoiceFailure.rateLimited),.rateLimited)
        XCTAssertEqual(VoiceFailure.from(CodexAuthError(.apiKey)),.apiKeySignIn)
        XCTAssertEqual(VoiceFailure.from(RealtimeError(.network)),.offline)
        XCTAssertEqual(VoiceFailure.from(CheckmateError.unavailable("Codex could not complete thread/start.")),.connectFailed)
        XCTAssertEqual(VoiceFailure.from(CheckmateError.unavailable("x"),fallback:.microphoneUnavailable),.microphoneUnavailable)
    }
    /// A known refusal keeps its own cause and action: Codex holding the session, a network game, a place the coach
    /// does not connect to, and consent withdrawn. Only an error nothing recognises is "could not connect".
    func testKnownRefusalsKeepTheirCause() {
        XCTAssertEqual(VoiceFailure.from(CheckmateError.invalid("SESSION_IN_USE")),.companionConnected)
        XCTAssertEqual(VoiceFailure.from(ProtocolFailure("SESSION_IN_USE","Another Codex task is connected.")),.companionConnected)
        XCTAssertEqual(VoiceFailure.from(CheckmateError.invalid(FairnessPolicy.refusal)),.networkGame)
        XCTAssertEqual(VoiceFailure.from(CheckmateError.invalid("UNSUPPORTED_MODE")),.notHere)
        XCTAssertEqual(VoiceFailure.from(ProtocolFailure("UNSUPPORTED_MODE","The voice coach connects only to a training game being played.")),.notHere)
        XCTAssertEqual(VoiceFailure.companionConnected.action,.openConnections);XCTAssertNil(VoiceFailure.networkGame.action);XCTAssertNil(VoiceFailure.notHere.action);XCTAssertEqual(VoiceFailure.consentNeeded.action,.tryAgain)
        XCTAssertEqual(VoiceFailure.from(CheckmateError.invalid("INVALID_ARGUMENT")),.connectFailed,"an unknown code is still unknown")
        XCTAssertEqual(VoiceFailure.from(URLError(.badServerResponse)),.connectFailed)
    }
    /// A refusal that reaches the connection attempt is shown as its own failure, not "could not connect".
    func testAConnectRefusedByCodexSaysSo()async throws {
        let s=try GameSession(engine:nil);s.state.settings.voiceConsent=true;let v=try VoiceCoach(session:s);defer{v.disconnect()}
        v.automationAuthorizationFailure=CheckmateError.invalid("SESSION_IN_USE");v.connect()
        for _ in 0..<300 where v.failure==nil {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(v.failure,.companionConnected);XCTAssertEqual(v.connection,.failed(VoiceFailure.companionConnected.cause))
        v.automationAuthorizationFailure=CheckmateError.invalid("NETWORK_GAME");v.connect()
        for _ in 0..<300 where v.failure != .networkGame {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(v.failure,.networkGame)
        v.automationAuthorizationFailure=VoiceFailure.consentNeeded;v.connect()
        for _ in 0..<300 where v.failure != .consentNeeded {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(v.failure,.consentNeeded)
    }
    /// Practice voice refused for the activity shown has its own code, so SESSION_IN_USE always means Codex.
    func testOpenVoiceRefusalsNameTheirCause()throws {
        let s=try GameSession(engine:nil)
        s.setConnection(enabled:true,role:"coach")
        XCTAssertThrowsError(try s.openVoice()){XCTAssertEqual(String(describing:$0),"SESSION_IN_USE")}
        s.setConnection(enabled:false,role:"coach");s.suspendForReview()
        XCTAssertThrowsError(try s.openVoice()){XCTAssertEqual(String(describing:$0),"UNSUPPORTED_MODE")}
    }
    /// The learner's thinking levels are three efforts; any other effort still has a name.
    func testThinkingLevelsNameTheirEffort() {
        XCTAssertEqual(CoachThinking.allCases.map(\.title),["Quick","Balanced","Thorough"])
        XCTAssertEqual(CoachThinking.allCases.map(\.rawValue),["minimal","low","high"])
        for level in CoachThinking.allCases {XCTAssertTrue(AppSettings.reasoningEfforts.contains(level.rawValue))}
        XCTAssertEqual(CoachThinking.name(effort:"xhigh"),"Extra high");XCTAssertEqual(CoachThinking.name(effort:"medium"),"Medium");XCTAssertEqual(CoachThinking.name(effort:"low"),"Balanced")
    }

    // MARK: V-22: the chosen model is kept for a day, across launches

    private func cacheFile()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("voice-model-\(UUID().uuidString).json")}
    func testTheChosenModelIsKeptForADayAcrossLaunches()async throws {
        let file=cacheFile();defer{try? FileManager.default.removeItem(at:file)}
        let date=Date(timeIntervalSince1970:1000);var probes:[String]=[]
        let first=VoiceModelSelection(storage:file)
        let chosen=try await first.resolve(effort:"minimal",now:date){probes.append($0);return $0=="gpt-realtime-2"}
        XCTAssertEqual(chosen,"gpt-realtime-2");XCTAssertTrue(FileManager.default.fileExists(atPath:file.path),"the choice is saved")
        // The next launch reads it and probes nothing.
        let next=VoiceModelSelection(storage:file)
        let cached=try await next.resolve(effort:"minimal",now:date.addingTimeInterval(3600)){_ in XCTFail("probed again");return false}
        XCTAssertEqual(cached,"gpt-realtime-2")
        // Another effort, or a day later, probes again.
        _ = try await VoiceModelSelection(storage:file).resolve(effort:"minimal",now:date.addingTimeInterval(VoiceModelSelection.cacheLifetime)){probes.append($0);return true}
        XCTAssertEqual(probes,["gpt-realtime-2.1","gpt-realtime-2","gpt-realtime-2.1"])
        // A failure forgets it on disk too.
        next.invalidate();XCTAssertFalse(FileManager.default.fileExists(atPath:file.path),"invalidate removes the saved choice")
    }
    func testASavedChoiceThatCannotBeTrustedIsProbedAgain()async throws {
        let file=cacheFile();defer{try? FileManager.default.removeItem(at:file)}
        let date=Date(timeIntervalSince1970:1000)
        for bad in [Data("not json".utf8),Data(#"{"model":"gpt-guessed","effort":"minimal","date":0}"#.utf8)] {
            try bad.write(to:file);var probes=0
            let model=try await VoiceModelSelection(storage:file).resolve(effort:"minimal",now:date){_ in probes+=1;return true}
            XCTAssertEqual(model,VoiceModelSelection.candidates[0]);XCTAssertEqual(probes,1,"a damaged or unknown choice is probed again")
        }
    }
    func testNoModelIsAFailureWithAnAction()async {
        let selection=VoiceModelSelection()
        do {_ = try await selection.resolve(effort:"xhigh"){_ in false};XCTFail("resolved")} catch {XCTAssertEqual(error as? VoiceFailure,.thinkingUnsupported)}
        do {_ = try await selection.resolve(effort:"minimal"){_ in false};XCTFail("resolved")} catch {XCTAssertEqual(error as? VoiceFailure,.noModel)}
    }

    // MARK: The coach reports typed failures

    private func coach()throws->(GameSession,VoiceCoach) {
        let session=try GameSession(engine:nil);session.state.settings.voiceMicrophone=false;session.state.settings.voiceConsent=true
        return (session,try VoiceCoach(session:session))
    }
    private func waitFor(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<200 {if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail(what)}
    func testAFailedConnectionKeepsItsFailureAndAction()async throws {
        let (_,voice)=try coach();defer{voice.disconnect()}
        voice.automationAuthorizationFailure=CheckmateError.unavailable("Codex could not complete account/read.");voice.connect()
        try await waitFor("the failure arrives"){!voice.connecting}
        XCTAssertEqual(voice.failure,.connectFailed);XCTAssertEqual(voice.connection,.failed(VoiceFailure.connectFailed.cause),"jargon goes to the log, not the learner")
        voice.disconnect();XCTAssertNil(voice.failure,"disconnecting clears it")
        voice.automationAuthorizationFailure=VoiceFailure.signInExpired;voice.connect()
        try await waitFor("the failure arrives"){!voice.connecting}
        XCTAssertEqual(voice.failure,.signInExpired);XCTAssertEqual(voice.status,VoiceFailure.signInExpired.cause)
    }
    /// The microphone's problem is typed too, so its button opens the right place.
    func testAMicrophoneProblemNamesItsAction()async throws {
        let (session,voice)=try coach();session.state.settings.voiceMicrophone=true;voice.settingsChanged()
        voice.automationCaptureStart={_ in throw VoiceFailure.microphoneDenied};voice.testMicrophone()
        try await waitFor("the test fails"){voice.microphoneFailure != nil}
        XCTAssertEqual(voice.microphoneFailure,.microphoneDenied);XCTAssertEqual(voice.status,VoiceFailure.microphoneDenied.cause)
        voice.automationCaptureStart={_ in};voice.testMicrophone()
        try await waitFor("the test opens the microphone"){voice.microphoneFailure==nil};voice.disconnect()
    }

    // MARK: V-5: voice without Codex is explained, never offered as working

    func testWithoutCodexVoiceIsExplainedNotOffered()throws {
        let (_,voice)=try coach();voice.voiceDouble=true;defer{voice.disconnect()}
        XCTAssertNil(voice.capability,"nothing is checked until the app asks");XCTAssertNil(voice.practiceVoiceUnavailability)
        voice.refreshCapability{VoiceCapability(codexInstalled:false,signInFileFound:false)}
        XCTAssertEqual(voice.capability?.usable,false);XCTAssertEqual(voice.practiceVoiceUnavailability,.codexMissing)
        XCTAssertEqual(voice.trainingVoiceUnavailability,.codexMissing)
        voice.connect();XCTAssertEqual(voice.connection,.unavailable(.codexMissing),"Connect explains instead of failing");XCTAssertFalse(voice.connecting)
        XCTAssertFalse(VoiceUnavailability.codexMissing.message.contains("MCP"));XCTAssertTrue(VoiceUnavailability.codexMissing.message.contains("Codex"))
        voice.refreshCapability{VoiceCapability(codexInstalled:false,signInFileFound:true)}
        XCTAssertEqual(voice.capability?.usable,true,"a ChatGPT sign-in file is enough without the app");XCTAssertNil(voice.practiceVoiceUnavailability)
        voice.refreshCapability{VoiceCapability(codexInstalled:true,signInFileFound:false)};XCTAssertEqual(voice.capability?.usable,true)
    }
    /// The check reads only the file system: where Codex is installed and whether its sign-in file exists.
    func testTheCapabilityCheckReadsTheFileSystem()throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:home)}
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        let empty=VoiceCapability.current(home:home,environment:["PATH":"/nonexistent"])
        // Codex may be installed system-wide on the test host, so the app's presence is compared, not assumed.
        XCTAssertFalse(empty.signInFileFound);XCTAssertEqual(empty.codexInstalled,CompanionInstallation.installedCodex(home:home,environment:["PATH":"/nonexistent"]) != nil)
        try FileManager.default.createDirectory(at:home.appendingPathComponent(".codex"),withIntermediateDirectories:true)
        try Data("{}".utf8).write(to:home.appendingPathComponent(".codex/auth.json"))
        XCTAssertTrue(VoiceCapability.current(home:home,environment:["PATH":"/nonexistent"]).signInFileFound)
    }
}
