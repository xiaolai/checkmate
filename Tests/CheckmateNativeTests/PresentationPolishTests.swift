import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// Small presentation decisions behind the sidebar, the inspector, the storage banner and Settings: each says a thing
/// once, offers only what can act, and counts what the learner can see.
@MainActor final class PresentationPolishTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}

    /// About counts what the sidebar lists: the main lessons its progress counts, the practice lessons under them,
    /// and every row of its Mini-games section.
    func testAboutCountsWhatTheSidebarShows()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let facts=AboutFacts(model:model),library=model.learning.library
        XCTAssertEqual(facts.lessons,model.learning.courseProgress.total,"the lesson count matches Learn & explore's progress")
        XCTAssertEqual(facts.practiceLessons,library.lessons.filter(\.isPractice).count)
        XCTAssertEqual(facts.miniGames,SidebarSelection.miniGames(library).count,"the mini-game count matches the sidebar's Mini-games rows")
        XCTAssertEqual(facts.miniGames,MiniGameKind.allCases.count)
    }
    /// Wording every relation shares is said once for the list; mixed wording stays with each relation.
    func testSharedRelationWordingIsSaidOnce(){
        XCTAssertEqual(RelationshipContent.sharedCaption(["Could capture.","Could capture."]),"Could capture.")
        XCTAssertNil(RelationshipContent.sharedCaption(["Could capture.","Covers this square."]))
        XCTAssertNil(RelationshipContent.sharedCaption(["Could capture."]),"one relation keeps its own caption")
        XCTAssertNil(RelationshipContent.sharedCaption([]))
    }
    /// The relationship panel is separated from what follows only when something follows without its own separator:
    /// the mode's content (no report shown) or the network panel. Practice's voice card brings its own.
    func testTheRelationshipPanelNeverDoublesASeparator(){
        XCTAssertTrue(DetailContent.separatesRelationships(reportShown:false,network:false))
        XCTAssertTrue(DetailContent.separatesRelationships(reportShown:true,network:true))
        XCTAssertFalse(DetailContent.separatesRelationships(reportShown:true,network:false))
    }
    /// A banner that tells the learner to export offers the export; other problems offer only Dismiss.
    func testTheProgressSaveFailureOffersExport(){
        XCTAssertTrue(StorageErrorBanner.offersProgressExport(NativeModel.progressSaveFailure))
        XCTAssertFalse(StorageErrorBanner.offersProgressExport(FairnessPolicy.destinationUnavailable))
        XCTAssertFalse(StorageErrorBanner.offersProgressExport(nil))
    }
    /// Remove Codex Setup shows only when there is something to remove: Codex's registration or the companion skill.
    func testRemoveCodexSetupShowsOnlyForASetup(){
        XCTAssertFalse(SettingsWindow.offersRemoval(setup:nil,skill:nil),"nothing read yet, or automation")
        XCTAssertFalse(SettingsWindow.offersRemoval(setup:.notSetUp,skill:.notInstalled))
        XCTAssertTrue(SettingsWindow.offersRemoval(setup:.current,skill:.notInstalled))
        XCTAssertTrue(SettingsWindow.offersRemoval(setup:.stale(registered:"/old"),skill:nil))
        XCTAssertTrue(SettingsWindow.offersRemoval(setup:.unknown,skill:nil))
        XCTAssertTrue(SettingsWindow.offersRemoval(setup:.notSetUp,skill:.outdated),"a skill left behind is still removable")
    }
}
