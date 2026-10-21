import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
import RealtimeConnection
import CodexAuth

/// Why voice cannot connect is told in words the learner can act on, and an account problem is never mistaken for an
/// incompatible model. No network: tokens and statuses are fixtures.
final class VoiceAuthorizationTests:XCTestCase {
    /// Every sign-in state Codex can be in names its own fix; none reads as a model or network problem.
    func testSignInStatesNameTheirFix() {
        let failing=CodexAuthState.allCases.filter{$0 != .ready}
        let messages=failing.map{userFacingMessage(VoiceGateway.signInFailure($0),fallback:"")}
        XCTAssertFalse(messages.contains(""))
        XCTAssertEqual(VoiceGateway.signInFailure(.apiKey),.apiKeySignIn);XCTAssertEqual(VoiceGateway.signInFailure(.expired),.signInExpired)
        XCTAssertEqual(VoiceGateway.signInFailure(.codexError).action,.tryAgain,"a Codex that did not answer is tried again, not signed in again")
        XCTAssertTrue(userFacingMessage(VoiceGateway.signInFailure(.codexTooOld),fallback:"").contains(minimumCodexVersion))
        XCTAssertTrue(userFacingMessage(VoiceGateway.signInFailure(.appServerAuthUnavailable),fallback:"").contains("keychain"))
        // Distinct fixes get distinct words: only not-signed-in and no-sign-in-file share "sign in first".
        XCTAssertEqual(Set(messages).count,failing.count-1,"\(messages)")
        // A sign-in failure reaching authorization is reported as that state, never as the service.
        XCTAssertEqual(VoiceGateway.authorizationFailure(CodexAuthError(.expired)) as? VoiceFailure,.signInExpired)
        XCTAssertEqual(VoiceGateway.authorizationFailure(CodexAuthError(.noCodex)) as? VoiceFailure,.noCodex)
    }
    /// The sign-in file is where sayso's CodexAuth reads it: CODEX_HOME when set (through links), else ~/.codex.
    func testCredentialFileFollowsCodexHome()throws {
        let home=URL(fileURLWithPath:"/Users/learner",isDirectory:true)
        XCTAssertEqual(VoiceGateway.credentialURL(environment:[:],home:home).path,"/Users/learner/.codex/auth.json")
        XCTAssertEqual(VoiceGateway.credentialURL(environment:["CODEX_HOME":""],home:home).path,"/Users/learner/.codex/auth.json")
        let real=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let link=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:real,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:real)
        defer{try? FileManager.default.removeItem(at:link);try? FileManager.default.removeItem(at:real)}
        XCTAssertEqual(VoiceGateway.credentialURL(environment:["CODEX_HOME":real.path],home:home).path,real.appendingPathComponent("auth.json").path)
        XCTAssertEqual(VoiceGateway.credentialURL(environment:["CODEX_HOME":link.path],home:home).path,real.appendingPathComponent("auth.json").path)
    }
    /// Translation names each sign-in state's fix in its own words, never voice's.
    func testTranslationSignInStatesNameTheirFix() {
        let failing=CodexAuthState.allCases.filter{$0 != .ready}
        let messages=failing.map{userFacingMessage(CodexSubscriptionClient.signInFailure($0),fallback:"")}
        XCTAssertFalse(messages.contains(""))
        XCTAssertEqual(Set(messages).count,failing.count-1,"\(messages)")
        for message in messages {XCTAssertTrue(message.contains("translat"),message);XCTAssertFalse(message.contains("connect"),message)}
    }
    /// A refused mint is classified by the package; Checkmate decides only the words and the model fallback.
    func testStatusesNameTheirCause() {
        func refused(_ status:Int)->Error {VoiceGateway.authorizationFailure(RealtimeError(RealtimeError.classify(status:status,code:""),status:status))}
        for status in [400,404,422] {XCTAssertTrue(refused(status) is VoiceGateway.ModelUnsupported,"\(status)")}
        let messages=[401,403,429,503,418].map{userFacingMessage(refused($0),fallback:"")}
        XCTAssertEqual(Set(messages).count,5,"each cause has its own message: \(messages)");XCTAssertFalse(messages.contains(""))
        XCTAssertTrue(messages[0].contains("not accepted"),"a 401 is not claimed to be an expiry")
        XCTAssertEqual(VoiceGateway.authorizationFailure(RealtimeError(.network)) as? VoiceFailure,.offline)
        XCTAssertTrue(VoiceGateway.authorizationFailure(RealtimeError(.cancelled)) is CancellationError)
        XCTAssertEqual(VoiceGateway.authorizationFailure(RealtimeError(.routeDenied,status:401,code:"missing_scope")) as? VoiceFailure,.accessRefused,"a missing scope is an account refusal, not a model")
    }
    /// An expired sign-in stops model selection with its own reason instead of "no supported model".
    @MainActor func testAccountFailureIsNotAnIncompatibleModel()async {
        let selection=VoiceModelSelection();var probed:[String]=[]
        do {_ = try await selection.resolve(effort:"minimal"){model in probed.append(model);throw VoiceFailure.signInExpired};XCTFail("resolved")}
        catch {XCTAssertEqual(error as? VoiceFailure,.signInExpired)}
        XCTAssertEqual(probed,[VoiceModelSelection.candidates[0]],"the account problem is not retried on every model")
    }
    /// When no model accepts a chosen effort above Minimal, the failure sends the learner to the thinking level.
    @MainActor func testNoModelForAnEffortNamesIt()async {
        let selection=VoiceModelSelection()
        do {_ = try await selection.resolve(effort:"xhigh"){_ in false};XCTFail("resolved")}
        catch {XCTAssertEqual(error as? VoiceFailure,.thinkingUnsupported);XCTAssertEqual((error as? VoiceFailure)?.action,.openVoiceSettings)}
        do {_ = try await selection.resolve(effort:"minimal"){_ in false};XCTFail("resolved")}
        catch {XCTAssertEqual(error as? VoiceFailure,.noModel)}
    }
    /// The probe reports only an unsupported model as incompatible; an authorization failure (here, automation
    /// refusing live voice before any request) is thrown with its reason.
    func testProbePassesAuthorizationFailuresThrough()async {
        do {let compatible=try await VoiceGateway().supportsCoach(model:"gpt-realtime-2.1",effort:"minimal",voice:"cedar",tools:[]);XCTFail("an authorization failure read as compatible=\(compatible)")}
        catch {XCTAssertEqual(userFacingMessage(error,fallback:""),"Live voice is disabled during automation.")}
    }
}
