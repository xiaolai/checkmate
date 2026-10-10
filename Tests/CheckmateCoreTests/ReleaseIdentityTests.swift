import XCTest
@testable import CheckmateCore
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
