import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// SH-1/SH-2/SH2-6: whatever the drawers and the proposed frame, the board area (frame less open drawers) stays square.
final class GapShellReviewTestsGeometry:XCTestCase {
    /// The exit-fullscreen restore proposes core+drawers; on every screen shape the clamped result keeps the board square and on screen.
    func testClampedRestoreKeepsTheBoardAreaSquareForEveryDrawerWidth(){
        let screens=[CGRect(x:0,y:0,width:1728,height:1084),CGRect(x:0,y:0,width:1280,height:1000),CGRect(x:0,y:0,width:1024,height:640),CGRect(x:-1920,y:0,width:1920,height:1080)]
        for screen in screens{for drawers in [0.0,217,321,538]{for proposal in [[0.0,0,780,780],[100,50,780+drawers,780],[99999,-9999,9000,9000],[0,0,2000,1400],[screen.minX+10,10,300,300],[screen.minX,0,1500,900]]{
            let r=WindowGeometry.restored(proposal,screens:[screen],drawers:drawers),board=r.width-drawers
            XCTAssertEqual(board,r.height,accuracy:0.001,"board area not square: screen \(screen) drawers \(drawers) proposal \(proposal) -> \(r)")
            XCTAssertTrue(screen.insetBy(dx:-0.001,dy:-0.001).contains(r),"restored frame off screen: \(r) on \(screen)")
            XCTAssertLessThanOrEqual(r.height,screen.height);XCTAssertLessThanOrEqual(r.width,screen.width)}}}
    }
    /// A frame saved on a large display restores onto the screen it overlaps most, squared to that screen's limits with the drawers kept.
    func testRestoreChoosesTheOverlappingScreenAndSquaresToItsLimits(){
        let big=CGRect(x:0,y:0,width:2560,height:1440),small=CGRect(x:2560,y:0,width:1280,height:800)
        let r=WindowGeometry.restored([2600,100,1400,1100],screens:[big,small],drawers:538)
        XCTAssertTrue(small.contains(r),"restored onto the wrong screen: \(r)");XCTAssertEqual(r.height,1280-538);XCTAssertEqual(r.width-538,r.height)
        let unsquared=WindowGeometry.restored([0,0,1400,900],screens:[big],square:false);XCTAssertEqual(unsquared.size,CGSize(width:1400,height:900),"square:false must leave the proposal alone (control)")
    }
    /// Drawers as wide as the screen leave no room: the board keeps its floor rather than a zero or negative side.
    func testDrawersWiderThanTheScreenKeepAPositiveBoard(){
        for (screen,drawers) in [(CGRect(x:0,y:0,width:500,height:400),538.0),(CGRect(x:0,y:0,width:538,height:600),538),(CGRect(x:0,y:0,width:700,height:900),538)]{
            let r=WindowGeometry.restored([0,0,1400,900],screens:[screen],drawers:drawers,minimumSide:320),board=r.width-drawers
            XCTAssertGreaterThanOrEqual(board,320,"board below its floor: screen \(screen) drawers \(drawers) -> \(r)");XCTAssertEqual(board,r.height,accuracy:0.001)
            XCTAssertEqual(r.minX,screen.minX,"an oversized frame starts at the screen's leading edge")}
        XCTAssertGreaterThan(WindowGeometry.restored([0,0,900,900],screens:[CGRect(x:0,y:0,width:400,height:400)],drawers:538).height,0,"the default floor is still positive")
    }
}

/// The live GameWindow delegate methods, driven on an unshown window: no app launch, no screen output.
@MainActor final class GapShellReviewTestsWindow:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    /// `inLiveResize` is read-only on NSWindow; a subclass reports a live drag so `windowWillResize` applies its rule.
    private final class LiveWindow:NSWindow {override var inLiveResize:Bool {true}}
    private func live(_ size:NSSize)->LiveWindow {LiveWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:true)}
    private func withWindow(_ body:(GameWindow,NativeModel)throws->Void)rethrows {let model=try! NativeModel();let game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()};try body(game,model)}
    private func drawers(_ g:GameWindow)->CGFloat {(g.sidebarItem.isCollapsed ? 0:g.leftExtent)+(g.inspectorItem.isCollapsed ? 0:g.rightExtent)}
    func testLiveResizeKeepsTheBoardSquareFollowingTheEdgeDraggedMost(){withWindow{g,_ in
        for (left,right) in [(false,false),(true,false),(true,true)]{g.sidebarItem.isCollapsed = !left;g.inspectorItem.isCollapsed = !right;let d=drawers(g)
            let w=live(NSSize(width:700+d,height:700)),limit=w.screen.map{min($0.visibleFrame.height,$0.visibleFrame.width-d)} ?? .greatestFiniteMagnitude,floor=min(Metrics.minimum,w.screen?.visibleFrame.height ?? Metrics.minimum)
            let wider=g.windowWillResize(w,to:NSSize(width:w.frame.width+60,height:w.frame.height+5))  // width dragged most
            XCTAssertEqual(wider.width-d,wider.height,"board not square with drawers \(d)");XCTAssertEqual(wider.height,max(floor,min(700+60,limit)))
            let taller=g.windowWillResize(w,to:NSSize(width:w.frame.width+5,height:w.frame.height+40))  // height dragged most
            XCTAssertEqual(taller.width-d,taller.height);XCTAssertEqual(taller.height,max(floor,min(w.frame.height+40,limit)))
            let huge=g.windowWillResize(w,to:NSSize(width:99999,height:20));XCTAssertEqual(huge.width-d,huge.height);if w.screen != nil{XCTAssertLessThanOrEqual(huge.height,limit,"a live resize must never exceed the screen")}
            XCTAssertEqual(g.fixedBoardWidth?.constant,huge.height,"the board width constraint follows the squared side")}
        g.sidebarItem.isCollapsed=true;g.inspectorItem.isCollapsed=true
        let notLive=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:true)
        XCTAssertEqual(g.windowWillResize(notLive,to:NSSize(width:900,height:640)),NSSize(width:900,height:640),"a programmatic resize is squared afterwards, not here")}}
    func testZoomUsesTheLargestSquareBoardTheScreenAllows(){withWindow{g,_ in
        let screen=NSRect(x:0,y:25,width:1728,height:1059)
        for (left,right) in [(false,false),(true,false),(false,true),(true,true)]{g.sidebarItem.isCollapsed = !left;g.inspectorItem.isCollapsed = !right;let d=drawers(g)
            let z=g.windowWillUseStandardFrame(g.window!,defaultFrame:screen)
            XCTAssertEqual(z.width-d,z.height,"Zoom left the board area unsquare with drawers \(d)");XCTAssertEqual(z.height,min(screen.height,screen.width-d));XCTAssertEqual(z.maxY,screen.maxY,"Zoom keeps the top edge");XCTAssertTrue(screen.contains(z))}
        g.sidebarItem.isCollapsed=false;g.inspectorItem.isCollapsed=false
        let narrow=g.windowWillUseStandardFrame(g.window!,defaultFrame:NSRect(x:0,y:0,width:1024,height:900));XCTAssertEqual(narrow.width-drawers(g),narrow.height);XCTAssertEqual(narrow.height,1024-drawers(g),"a narrow screen limits the side by its width less the drawers")}}
    /// Any non-live resize (Fill, tiling, a display change) is re-squared from the new height; the stretched frame is never kept or saved.
    func testProgrammaticStretchIsResquaredAndSavedSquare(){withWindow{g,model in
        let window=g.window!;window.setFrame(NSRect(x:120,y:80,width:1100,height:640),display:false)
        let d=drawers(g);XCTAssertEqual(window.frame.width-d,window.frame.height,accuracy:1,"stretched frame not re-squared: \(window.frame)")
        XCTAssertEqual(g.fixedBoardWidth?.constant ?? 0,window.frame.height,accuracy:1)
        let saved=model.session.state.window.frame;XCTAssertEqual(saved?.count,4);if let saved,saved.count==4{XCTAssertEqual(saved[2],saved[3],accuracy:1,"a stretched frame was saved")}}}

    /// SH2-1: the last-move squares, the checked king and an ordinary square carry distinct labels, wired by refresh() from the real game.
    /// The spoken move/check/mate announcement itself is posted straight to NSAccessibility with no string seam, so it is not observed here.
    func testLastMoveAndCheckSquaresGetDistinctAccessibilityLabels()throws {try withWindow{g,model in
        model.session.newGame(side:"w");try model.session.rules.restore("1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#");g.refresh()
        @MainActor func label(_ sq:String)->String {SquareAccessibility(board:g.board,square:sq).accessibilityLabel() ?? ""}
        XCTAssertEqual(label("f7"),"f7, White, queen, part of the last move");XCTAssertEqual(label("h5"),"h5, part of the last move")
        XCTAssertEqual(label("e8"),"e8, Black, king, in check");XCTAssertEqual(label("h4"),"h4");XCTAssertEqual(label("c4"),"c4, White, bishop")
        try model.session.rules.restore("1. e4 e5 2. Nf3");g.refresh()
        XCTAssertEqual(label("g1"),"g1, part of the last move");XCTAssertEqual(label("f3"),"f3, White, knight, part of the last move");XCTAssertFalse(label("e8").contains("in check"));XCTAssertFalse(label("f7").contains("last move"),"an earlier move's squares must lose the marker")
        model.session.cancelWork()}}
}

/// SH-5/B7: scenario flags run only in an isolated automation process. XCTest is always silent and this bundle is never the
/// release identifier, so only the data-directory leg is variable here; the release-identifier leg has no injection seam.
@MainActor final class GapShellReviewTestsPolicy:XCTestCase {
    func testIsolationRequiresAnExplicitDataDirectory(){
        let saved=ProcessInfo.processInfo.environment["CHECKMATE_DATA_DIR"];defer{if let saved{setenv("CHECKMATE_DATA_DIR",saved,1)}else{unsetenv("CHECKMATE_DATA_DIR")}}
        XCTAssertTrue(NativePolicy.silent);XCTAssertNotEqual(Bundle.main.bundleIdentifier,"ai.xiaolai.checkmate","test host must not carry the release identifier")
        unsetenv("CHECKMATE_DATA_DIR");XCTAssertFalse(AppDelegate.isolatedAutomation,"scenario flags accepted without an isolated data directory")
        setenv("CHECKMATE_DATA_DIR",FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,1);XCTAssertTrue(AppDelegate.isolatedAutomation,"a silent, isolated, non-release process must accept scenario flags")
    }
}

/// TX-1/RV-8: review saves are tracked per record; a failure stays pending and visible until that record saves.
@MainActor final class GapShellReviewTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func game(_ pgn:String)throws -> GameDocument {try PGNImporter.parse(Data(pgn.utf8),provenance:pgn)[0]}
    /// A record file from a newer version blocks saves of exactly that record and nothing else.
    private func block(_ model:NativeModel,_ id:UUID)throws {try FileManager.default.createDirectory(at:model.reviewStore.directory,withIntermediateDirectories:true);try Data(#"{"schemaVersion":2}"#.utf8).write(to:model.reviewStore.documentURL(id))}
    private static let newerVersion="The review could not be saved: This review requires a newer Checkmate version; its file is preserved. Export the original PGN before quitting."
    func testAnotherReviewsSuccessfulSaveNeverClearsAFailedReviewsWarning()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let first=try game("1. e4 e5 *");try block(model,first.id)
        model.openReview(first);model.saveCurrentReview()
        XCTAssertEqual(model.storageError,Self.newerVersion,"the warning must name the real error")
        // Several other reviews save successfully; the order they and the failed record are retried in varies, so repeat.
        var others:[GameDocument]=[]
        for (i,opening) in ["d4","c4","Nf3","g3","b3","f4","Nc3","b4"].enumerated(){let other=try game("1. \(opening) *");others.append(other);model.openReview(other);XCTAssertTrue(model.saveReview(immediate:true),"the open review saved");XCTAssertEqual(model.storageError,Self.newerVersion,"review \(i)'s success cleared the failed review's warning")}
        XCTAssertEqual(Set(try model.reviewStore.list().map(\.id)),Set(others.map(\.id)),"every other review was written; the blocked one was not")
        // The failed record stayed pending: once its blocker is gone, the next save of any review writes it and only then clears the warning.
        try FileManager.default.removeItem(at:model.reviewStore.documentURL(first.id));model.saveCurrentReview()
        XCTAssertEqual(try model.reviewStore.load(first.id).document.id,first.id,"the failed review was dropped instead of kept pending");XCTAssertNil(model.storageError,"its own success clears the warning")
    }
    func testDraftSaveFailureNamesTheLibraryLimitAndKeepsSaveAvailable()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try game("1. e4 e5 *");model.openReview(document,draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
        // A sparse file makes the library look full without using the disk.
        try FileManager.default.createDirectory(at:model.reviewStore.directory,withIntermediateDirectories:true);let filler=model.reviewStore.directory.appendingPathComponent("filler.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath:filler.path,contents:nil));let handle=try FileHandle(forWritingTo:filler);try handle.truncate(atOffset:UInt64(ReviewPolicy.maximumLibraryBytes));try handle.close()
        model.saveCurrentReview()
        XCTAssertEqual(model.storageError,"The review could not be saved: Review library storage limit reached; export or delete older reviews. Export the original PGN before quitting.")
        XCTAssertTrue(model.reviewDraft,"a failed save must leave the draft's Save Review button");XCTAssertTrue(model.review.active)
        let app=AppDelegate();app.model=model;XCTAssertTrue(app.validateMenuItem(NSMenuItem(title:"Save Review",action:#selector(AppDelegate.saveCurrentReview),keyEquivalent:"s")),"File > Save Review must stay enabled after a failure")
        try FileManager.default.removeItem(at:filler);model.saveCurrentReview()
        XCTAssertFalse(model.reviewDraft);XCTAssertNil(model.storageError,"the retried save's success clears its warning");XCTAssertEqual(try model.reviewStore.load(document.id).branches.map(\.moves),[["c7c5"]])
    }
    func testRecordLimitFailureNamesTheLimit()throws {
        let model=try NativeModel();defer{model.shutdown()}
        // A full library: 1000 indexed records. The index is trusted while every file's stamp matches and its titles follow
        // the current title rule (`titleRule`), so the records are never parsed.
        let files=FileManager.default,reviews=model.reviewStore.directory;try files.createDirectory(at:reviews,withIntermediateDirectories:true)
        var entries:[ReviewIndexEntry]=[],stamps:[String:String]=[:]
        for i in 0..<ReviewPolicy.maximumSavedRecords{let id=UUID(),url=model.reviewStore.documentURL(id);try Data("{}".utf8).write(to:url);let v=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            stamps[id.uuidString]="\(v.fileSize ?? -1):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)";entries.append(ReviewIndexEntry(id:id,title:"Game \(i)",result:"*",updatedAt:Date()))}
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(entries))
        try JSONSerialization.data(withJSONObject:["schemaVersion":1,"entries":encoded,"stamps":stamps,"titleRule":1]).write(to:reviews.appendingPathComponent("index.json"))
        XCTAssertEqual(try ReviewStore(directory:reviews).list().count,ReviewPolicy.maximumSavedRecords,"fixture: the forged index must be trusted")
        let document=try game("1. e4 e5 *");model.openReview(document)
        XCTAssertFalse(model.saveReview(immediate:true))
        XCTAssertEqual(model.storageError,"The review could not be saved: Review library record limit reached. Export the original PGN before quitting.")
    }
}

/// SH2-1: VoiceOver hears who moved, and check, mate or a draw, from the learner's side of the board.
@MainActor final class GapShellReviewTestsAnnouncements:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    func testMovesCheckAndMateAreAnnouncedFromTheLearnersSide()throws {
        let model=try NativeModel();let game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        model.session.newGame(side:"w");let rules=model.session.rules
        XCTAssertEqual(game.announcement(for:try rules.move("e2","e4")),"You played e4.")
        try rules.restore("1. d4 e6 2. Nf3 *")
        XCTAssertEqual(game.announcement(for:try rules.move("f8","b4")),"Black played Bb4+. Your king is in check.")
        try rules.restore("1. e4 f6 2. d4 g5 *")
        XCTAssertEqual(game.announcement(for:try rules.move("d1","h5")),"You played Qh5#. Checkmate. You win.")
        try rules.restore("1. f3 e5 2. g4 *")
        XCTAssertEqual(game.announcement(for:try rules.move("d8","h4")),"Black played Qh4#. Checkmate.")
        model.session.cancelWork()
    }
}
