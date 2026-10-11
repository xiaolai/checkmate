import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class ReleaseIdentityTests:XCTestCase {
    func testReleaseUsesCompanionDiscoveryNamespace() {
        XCTAssertEqual(StateStore.dataDirectoryIdentifier(bundleIdentifier:"ai.xiaolai.checkmate"),"ai.xiaolai.checkmate")
    }
    func testDevelopmentAndUnbundledTestsRemainIsolated() {
        for identity in [nil,"ai.xiaolai.checkmate.native-development","ai.xiaolai.checkmate.automation"] {
            XCTAssertEqual(StateStore.dataDirectoryIdentifier(bundleIdentifier:identity),"ai.xiaolai.checkmate.native-development")
        }
    }
}
