import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


private final class AccountStampFixture:@unchecked Sendable {
    private let lock=NSLock()
    private var stamp="signed-in-one"
    func read()->String {lock.lock();defer{lock.unlock()};return stamp}
    func change(){lock.lock();stamp="signed-out";lock.unlock()}
}
private struct AccountStatusProvider:LessonTranslationProvider {
    func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult{throw CancellationError()}
    func accountStatus()async throws->String{"Account limits fixture: 10 percent used."}
}
/// An account that cannot be read, for the reason given (nil: an error with no reason for the learner).
private struct FailingAccountProvider:LessonTranslationProvider {
    let reason:String?
    func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult{throw CancellationError()}
    func accountStatus()async throws->String{if let reason{throw CheckmateError.unavailable(reason)};throw URLError(.cannotConnectToHost)}
}
@MainActor final class LessonAccountStatusTests:XCTestCase {
    /// V-17: a failed refresh says why, when the reason is known, instead of a generic line.
    func testAFailedRefreshKeepsItsSpecificReason()async throws {
        for reason in ["Codex on this Mac is too old to translate lessons. Update Codex, then try again.",nil] {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:directory)}
            let controller=try LessonLanguageController(library:CourseLibrary(),directory:directory,usage:UsageLedger(directory:directory.appendingPathComponent("Usage")),translator:FailingAccountProvider(reason:reason),accountAuthMetadata:{"signed-in"})
            defer{controller.shutdown()}
            controller.refreshAccount()
            for _ in 0..<100{if controller.accountStatus.hasPrefix("Account status unavailable"){break};try await Task.sleep(for:.milliseconds(10))}
            XCTAssertEqual(controller.accountStatus,"Account status unavailable. "+(reason ?? "Refresh explicitly after signing in."))
        }
    }
    func testMetadataChangeMarksTimestampedSnapshotStaleWithoutRefreshing()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let stamp=AccountStampFixture(),ledger=UsageLedger(directory:directory.appendingPathComponent("Usage"))
        let controller=try LessonLanguageController(library:CourseLibrary(),directory:directory,usage:ledger,translator:AccountStatusProvider(),accountAuthMetadata:{stamp.read()})
        defer{controller.shutdown()}
        controller.refreshAccount()
        for _ in 0..<100{if controller.accountStatus.contains("Refreshed"){break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(controller.accountStatus.contains("Refreshed"))
        stamp.change();await controller.checkAccountAuthenticationMetadata()
        XCTAssertTrue(controller.accountStatus.contains("Codex sign-in file changed"))
        XCTAssertTrue(controller.accountStatus.contains("Stale account snapshot from"))
        XCTAssertTrue(controller.accountStatus.contains("10 percent used"))
        XCTAssertFalse(controller.accountStatus.contains("\nRefreshed"))
    }
}
