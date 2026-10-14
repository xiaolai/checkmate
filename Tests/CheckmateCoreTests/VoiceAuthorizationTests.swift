import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent

/// Why voice cannot connect is told in words the learner can act on, and an account problem is never mistaken for an
/// incompatible model. No network: tokens and statuses are fixtures.
final class VoiceAuthorizationTests:XCTestCase {
    private func token(_ claims:[String:Any])->String {
        func part(_ object:[String:Any])->String {(try! JSONSerialization.data(withJSONObject:object)).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
        return part(["alg":"none"])+"."+part(claims)+".signature"
    }
    func testExpiredCodexSignInIsNamed() {
        let now=Date(timeIntervalSince1970:1_000_000)
        XCTAssertNotNil(VoiceGateway.expiredSignIn(token(["exp":999_000]),now:now),"expired")
        XCTAssertNotNil(VoiceGateway.expiredSignIn(token(["exp":1_000_030]),now:now),"expires within a minute")
        XCTAssertNil(VoiceGateway.expiredSignIn(token(["exp":1_100_000]),now:now),"still valid")
        XCTAssertNil(VoiceGateway.expiredSignIn("opaque-token",now:now),"no readable expiry is left to the provider")
        XCTAssertNil(VoiceGateway.expiredSignIn(token(["sub":"x"]),now:now))
        XCTAssertEqual(userFacingMessage(VoiceGateway.expiredSignIn(token(["exp":1]),now:now)!,fallback:""),"Your Codex sign-in has expired. Open Codex once to refresh it, then connect again.")
    }
    func testCodexCredentialSources()throws {
        func credential(_ json:String)throws->String {try VoiceGateway.accessToken(Data(json.utf8))}
        // Only the ChatGPT subscription sign-in is used; an API key is never read, whatever else the file holds.
        XCTAssertEqual(try credential(#"{"tokens":{"access_token":"token"},"OPENAI_API_KEY":null}"#),"token")
        XCTAssertEqual(try credential(#"{"auth_mode":"chatgpt","OPENAI_API_KEY":"key","tokens":{"access_token":"token"}}"#),"token")
        for apiKey in [#"{"auth_mode":"apikey","OPENAI_API_KEY":"key","tokens":null}"#,#"{"auth_mode":"apikey","OPENAI_API_KEY":"key","tokens":{"access_token":"token"}}"#] {
            XCTAssertThrowsError(try credential(apiKey)){XCTAssertEqual(userFacingMessage($0,fallback:""),userFacingMessage(VoiceGateway.apiKeySignIn,fallback:""))}
        }
        XCTAssertThrowsError(try credential(#"{"OPENAI_API_KEY":"key"}"#),"a key without a ChatGPT sign-in")
        XCTAssertThrowsError(try credential(#"{"tokens":{"access_token":""}}"#))
    }
    func testStatusesNameTheirCause() {
        for status in [400,404,422] {XCTAssertTrue(VoiceGateway.authorizationFailure(status:status) is VoiceGateway.ModelUnsupported,"\(status)")}
        let messages=[401,403,429,503,418].map{userFacingMessage(VoiceGateway.authorizationFailure(status:$0),fallback:"")}
        XCTAssertEqual(Set(messages).count,5,"each cause has its own message: \(messages)");XCTAssertFalse(messages.contains(""))
        XCTAssertTrue(messages[0].contains("not accepted"),"a 401 is not claimed to be an expiry")
    }
    /// An expired sign-in stops model selection with its own reason instead of "no supported model".
    @MainActor func testAccountFailureIsNotAnIncompatibleModel()async {
        let selection=VoiceModelSelection();var probed:[String]=[]
        do {_ = try await selection.resolve(effort:"minimal"){model in probed.append(model);throw VoiceGateway.signInExpired};XCTFail("resolved")}
        catch {XCTAssertEqual(userFacingMessage(error,fallback:""),userFacingMessage(VoiceGateway.signInExpired,fallback:""))}
        XCTAssertEqual(probed,[VoiceModelSelection.candidates[0]],"the account problem is not retried on every model")
    }
    /// When no model accepts a chosen effort above Minimal, the message names the effort to lower.
    @MainActor func testNoModelForAnEffortNamesIt()async {
        let selection=VoiceModelSelection()
        do {_ = try await selection.resolve(effort:"xhigh"){_ in false};XCTFail("resolved")}
        catch {XCTAssertTrue(userFacingMessage(error,fallback:"").contains("supports Extra high reasoning"))}
        do {_ = try await selection.resolve(effort:"minimal"){_ in false};XCTFail("resolved")}
        catch {XCTAssertEqual(userFacingMessage(error,fallback:""),"No supported voice model is available for this account.")}
    }
    /// The probe reports only an unsupported model as incompatible; an authorization failure (here, automation
    /// refusing live voice before any request) is thrown with its reason.
    func testProbePassesAuthorizationFailuresThrough()async {
        do {let compatible=try await VoiceGateway().supportsCoach(model:"gpt-realtime-2.1",effort:"minimal",voice:"cedar",tools:[]);XCTFail("an authorization failure read as compatible=\(compatible)")}
        catch {XCTAssertEqual(userFacingMessage(error,fallback:""),"Live voice is disabled during automation.")}
    }
}
