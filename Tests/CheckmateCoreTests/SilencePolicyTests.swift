import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// Tests that prove "live services are disabled" would instead reach them if silence depended on the environment:
/// a paid realtime recording, the user's Codex sign-in or the real microphone.
final class SilencePolicyTests:XCTestCase {
    func testUnitTestsAreSilentWithoutTheAutomationVariable(){
        let saved=ProcessInfo.processInfo.environment["CHECKMATE_AUTOMATION"],xcode=ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
        unsetenv("CHECKMATE_AUTOMATION");unsetenv("XCTestConfigurationFilePath")
        defer{if let saved{setenv("CHECKMATE_AUTOMATION",saved,1)};if let xcode{setenv("XCTestConfigurationFilePath",xcode,1)}}
        XCTAssertTrue(NativePolicy.silent)
    }
}
