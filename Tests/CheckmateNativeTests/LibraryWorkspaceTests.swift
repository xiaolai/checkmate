import CheckmateTestSupport
import XCTest
import AppKit
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateNative

/// The review workspace's library as the learner uses it: a file of many games becomes a collection (R-9), saved
/// reviews are a library scope with a short sidebar list and Rename (R-11), the inspector previews the selected game
/// (R-26), and the sidebar reaches the mini-games (L-33).
@MainActor final class LibraryWorkspaceTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<500{if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail("timed out waiting for \(what)")}
    private func save(_ model:NativeModel,_ text:String)throws -> UUID {let document=try PGNImporter.parse(Data(text.utf8))[0];model.openReview(document);XCTAssertTrue(model.returnToGame());return document.id}

    /// R-9: no chooser of up to a thousand games. The file joins My Games as a collection named after its event, its
    /// first game is selected, and nothing opens until the learner chooses.
    func testAFileOfSeveralGamesBecomesASelectedCollection()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let games=(1...3).map{"[Event \"Club Night\"]\n[White \"W\($0)\"]\n[Black \"B\($0)\"]\n\n1. e4 e5 *"}.joined(separator:"\n\n")
        model.importReviewData(Data(games.utf8))
        try await settle("the collection to be selected"){model.library.selection?.hasPrefix("collection:")==true}
        XCTAssertTrue(model.reviewWorkspace);XCTAssertNil(model.review.document,"nothing opens until the learner chooses")
        XCTAssertEqual(model.library.scope,.myGames);XCTAssertEqual(model.library.query,"")
        let rows=model.library.visibleRows;XCTAssertEqual(rows.map(\.title),["W1 – B1","W2 – B2","W3 – B3"]);XCTAssertEqual(model.library.selection,rows.first?.id)
        XCTAssertEqual(model.library.catalog.sections(scope:.myGames,query:"").first?.title,"Club Night")
        try await settle("the preview of the first game"){model.library.preview?.id==rows.first?.id}
        let preview=try XCTUnwrap(model.library.preview);XCTAssertEqual(preview.details,["Club Night"]);XCTAssertEqual(preview.summary,"Unfinished · 1 move")
        model.library.open(rows[1]);try await settle("the second game to open"){model.review.document?.header("White")=="W2"}
    }
    /// A file of more games than one review reads (1,000) is still within a collection's limit (20,000): it becomes a
    /// collection, not a refusal.
    func testAFileOfMoreGamesThanAReviewReadsBecomesACollection()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let games=(1...ReviewPolicy.maximumRecords+1).map{"[Event \"Big Club\"]\n[White \"W\($0)\"]\n[Black \"B\($0)\"]\n\n1. e4 e5 *"}.joined(separator:"\n\n")
        model.importReviewData(Data(games.utf8))
        try await settle("the collection to be selected"){(model.library.selection?.hasPrefix("collection:")==true && !model.library.catalog.collections.isEmpty) || model.storageError != nil}
        XCTAssertNil(model.storageError);XCTAssertNil(model.review.document,"nothing opens until the learner chooses")
        XCTAssertEqual(model.library.catalog.collections.map{$0.0.records.count},[ReviewPolicy.maximumRecords+1])
    }
    /// A file of more games than a collection holds (20,000) is refused with that reason alone, the count grouped as the
    /// app shows counts and no record or token named, and nothing is added or opened.
    func testAFileOfMoreGamesThanACollectionHoldsIsRefused()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let games=(1...GameCollectionStore.maximumRecords+1).map{"[White \"W\($0)\"]\n\n1. e4 *"}.joined(separator:"\n\n")
        model.importReviewData(Data(games.utf8))
        for _ in 0..<3000 where model.storageError==nil{try await Task.sleep(for:.milliseconds(20))}
        let message=try XCTUnwrap(model.storageError,"the import was refused")
        XCTAssertEqual(GameCollectionStore.maximumRecords,20_000);XCTAssertEqual(message,"The file has more than 20,000 games.")
        XCTAssertTrue(model.library.catalog.collections.isEmpty,"nothing joined the library");XCTAssertNil(model.review.document,"nothing opened")
    }
    /// R-11: the library's Saved scope lists every saved review, follows renames, and the sidebar keeps a short list
    /// that always includes the review open.
    func testSavedReviewsAreListedRenamedAndKeptShortInTheSidebar()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let first=try save(model,"[White \"Ana\"]\n[Black \"Ben\"]\n\n1. d4 *"),second=try save(model,"[White \"Cy\"]\n[Black \"Di\"]\n\n1. c4 *")
        try await settle("both saved"){model.reviews.count==2}
        _ = model.library;model.library.scope = .saved
        try await settle("the Saved scope to list both"){model.library.visibleRows.count==2}
        XCTAssertEqual(Set(model.library.visibleRows.map(\.id)),Set([first,second].map{"saved:"+$0.uuidString}))
        let original=try XCTUnwrap(model.reviews.first{$0.id==first}?.title)
        model.renameReview(first,to:"  Club final  ")
        try await settle("the rename"){model.reviews.first{$0.id==first}?.title=="Club final"}
        try await settle("the library to follow"){model.library.visibleRows.contains{$0.title=="Club final"}}
        let reopened=try NativeModel();defer{reopened.shutdown()}
        try await settle("the reopened list"){reopened.reviews.count==2};XCTAssertEqual(reopened.reviews.first{$0.id==first}?.title,"Club final","the name is stored")
        model.renameReview(first,to:"");try await settle("the game's own title back"){model.reviews.first{$0.id==first}?.title==original}
        // The sidebar list: the newest eight, plus the open one when it is older.
        let entries=(0..<12).map{ReviewIndexEntry(id:UUID(),title:"Game \($0)",result:"*",updatedAt:Date(timeIntervalSince1970:Double(1000-$0)))}
        XCTAssertEqual(SidebarSelection.recentReviews(entries,open:nil).map(\.title),(0..<8).map{"Game \($0)"})
        XCTAssertEqual(SidebarSelection.recentReviews(entries,open:entries[10].id).map(\.title),(0..<8).map{"Game \($0)"}+["Game 10"])
        XCTAssertEqual(SidebarSelection.recentReviews(entries,open:entries[3].id).count,8)
    }
    /// R-26: the inspector shows the selected game's details and final position, which VoiceOver reads piece by piece.
    func testThePreviewBoardIsTheFinalPositionReadAloudPieceByPiece()throws {
        let document=try PGNImporter.parse(Data("[Event \"Test\"]\n[Site \"Club\"]\n[Date \"2024.??.??\"]\n[Round \"3\"]\n[Result \"1-0\"]\n\n1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0".utf8))[0]
        let row=LibraryRow(id:"r",source:.saved(document.id),title:"Mate",details:"",result:"1-0",facts:nil,accessibilityLabel:"Mate",searchKey:"")
        let preview=LibraryPreview.of(row,document:document)
        XCTAssertEqual(preview.details,["Test","Club","2024","Round 3"]);XCTAssertEqual(preview.summary,"1–0 · 4 moves")
        let squares=PositionThumbnail.squares(try XCTUnwrap(preview.fen));XCTAssertEqual(squares.count,64)
        XCTAssertEqual(squares[13],"wq","f7 holds the white queen");XCTAssertEqual(squares[4],"bk","e8 holds the black king")
        XCTAssertEqual(PositionThumbnail.description("6k1/8/8/8/8/8/8/5RK1 w - - 0 1"),"White: king g1, rook f1. Black: king g8.")
        XCTAssertEqual(PositionThumbnail.squares("not a position"),Array(repeating:nil,count:64),"an unreadable position draws an empty board")
    }
    /// L-33: each mini-game whose lesson is in the course is in the sidebar, and choosing one opens it from its lesson.
    func testTheSidebarOpensEachMiniGameFromItsLesson()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let entries=SidebarSelection.miniGames(model.learning.library)
        XCTAssertEqual(Set(entries.map(\.kind)),Set(MiniGameKind.allCases),"every mini-game is reachable")
        for entry in entries{XCTAssertEqual(model.learning.library.lessons[entry.lesson].id,entry.kind.lessonID)}
        model.playMiniGame(.knightCorners)
        guard case .miniGame(let lesson,let kind,_)=model.session.activity.place else{return XCTFail("no mini-game opened: \(model.session.activity.place)")}
        XCTAssertEqual(kind,.knightCorners);XCTAssertEqual(lesson.map{model.learning.library.lessons[$0].id},"knight-practice")
        XCTAssertFalse(model.learning.miniFromLibrary,"it returns to its lesson, not to training")
    }
}
