import XCTest
import CheckmateDomain
/// Edition 1 progress loads in edition 2 terms. The shipped tables name retired identifiers by digest only, so these
/// tests use stand-in retired names with tables built the same way.
final class ProgressMigrationTests:XCTestCase {
    private let lessons=[ProgressMigration.digest("retired-a"):"castling",ProgressMigration.digest("retired-b"):"castling",ProgressMigration.digest("retired-c"):"board"]
    private let games=[ProgressMigration.digest("retired-game"):"pawn-duel"]
    private func json(_ text:String)throws -> [String:JSONValue] {try JSONDecoder().decode([String:JSONValue].self,from:Data(text.utf8))}
    private func object(_ value:JSONValue?)->[String:JSONValue] {if case .object(let o)?=value{return o};return [:]}

    func testEditionOneCourseRenamesLessonsAndRestartsReplacedContent()throws {
        let raw=try json(#"{"course":{"lessonID":"retired-a","step":7,"segmentID":"retired-a:7","positions":{"pawn":"pawn:3"},"completed":["retired-a","retired-b","pawn","retired-c"],"answered":["pawn:2"]},"puzzles":{"course:pawn:1":{"solved":true,"review":false,"attempts":2}}}"#)
        let course=object(ProgressMigration.migrate(state:raw,lessons:lessons,games:games)["course"])
        XCTAssertEqual(course["lessonID"],.string("castling"))
        XCTAssertEqual(course["completed"],.array([.string("castling"),.string("pawn"),.string("board")]),"two retired lessons merged into one stay one completion, in order")
        XCTAssertEqual(course["step"],.integer(0));XCTAssertNil(course["segmentID"]);XCTAssertNil(course["positions"]);XCTAssertEqual(course["answered"],.array([]))
        XCTAssertEqual(course["edition"],.integer(Int64(ProgressMigration.courseEdition)))
        XCTAssertEqual(ProgressMigration.migrate(state:raw,lessons:lessons,games:games)["puzzles"],.object([:]),"every puzzle was replaced")
    }
    func testCurrentEditionIsUnchangedAndMigrationIsIdempotent()throws {
        let current=try json(#"{"course":{"lessonID":"pawn","step":3,"segmentID":"pawn:3","positions":{"pawn":"pawn:3"},"completed":["intro"],"answered":["pawn:1"],"edition":2},"puzzles":{"course:pawn:1":{"solved":true,"review":false,"attempts":1}}}"#)
        XCTAssertEqual(ProgressMigration.migrate(state:current,lessons:lessons,games:games),current)
        let old=try json(#"{"course":{"lessonID":"retired-c","step":4,"completed":["retired-c"],"answered":[]},"puzzles":{}}"#)
        let once=ProgressMigration.migrate(state:old,lessons:lessons,games:games)
        XCTAssertEqual(ProgressMigration.migrate(state:once,lessons:lessons,games:games),once)
    }
    func testRetiredMiniGameRestartsInItsRenamedGameKeepingTheOpponentChoice()throws {
        let raw=try json(#"{"miniGames":{"retired-game":{"computer":false,"kind":"retired-game"},"unknown-future-game":{"computer":true}}}"#)
        let games=object(ProgressMigration.migrate(state:raw,lessons:lessons,games:self.games)["miniGames"])
        XCTAssertNil(games["retired-game"])
        let restarted=try JSONDecoder().decode(MiniGameState.self,from:JSONEncoder().encode(games["pawn-duel"]!))
        XCTAssertEqual(restarted.kind,.pawnDuel);XCTAssertFalse(restarted.computer);XCTAssertEqual(restarted.board,MiniGameKind.pawnDuel.initialBoard)
        XCTAssertNotNil(games["unknown-future-game"],"a game this build does not know is left for the decoder, as before")
        // A game already saved under its new name wins over the retired copy.
        let both=try json(#"{"miniGames":{"retired-game":{"computer":false},"pawn-duel":{"marker":true}}}"#)
        XCTAssertEqual(object(ProgressMigration.migrate(state:both,lessons:lessons,games:self.games)["miniGames"])["pawn-duel"],.object(["marker":.bool(true)]))
    }
    func testTrainingRecordsFollowTheRenamedGame()throws {
        let raw=try json(#"{"version":1,"summaries":{"retired-game":{"attempts":0},"mate-in-one":{"attempts":0}},"creditedRuns":{"retired-game":"run-1"},"events":[{"kind":"retired-game","id":"e"}],"attempts":[{"entry":"retired-game","id":"a"}],"retryQueue":[{"entry":"mate-in-one","id":"r"}],"active":{"entry":"retired-game"}}"#)
        let training=object(ProgressMigration.migrate(training:.object(raw),games:games))
        XCTAssertEqual(Set(object(training["summaries"]).keys),["pawn-duel","mate-in-one"])
        XCTAssertEqual(object(training["creditedRuns"]),["pawn-duel":.string("run-1")])
        XCTAssertEqual(training["events"],.array([.object(["kind":.string("pawn-duel"),"id":.string("e")])]))
        XCTAssertEqual(training["attempts"],.array([.object(["entry":.string("pawn-duel"),"id":.string("a")])]))
        XCTAssertEqual(training["retryQueue"],.array([.object(["entry":.string("mate-in-one"),"id":.string("r")])]))
        XCTAssertEqual(object(training["active"])["entry"],.string("pawn-duel"))
    }
    /// The loader keeps fields it does not know and writes them back; a migrated state must not bring the dropped
    /// reading positions back that way.
    func testLoadedEditionOneStateWritesNoDroppedFields()throws {
        var state=ApplicationState();state.course.positions=["pawn":"pawn:3"];state.course.step=3
        var saved=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as? [String:Any])
        var course=saved["course"] as! [String:Any];course.removeValue(forKey:"edition");saved["course"]=course
        let loaded=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:saved))
        XCTAssertNil(loaded.course.positions);XCTAssertEqual(loaded.course.step,0);XCTAssertEqual(loaded.course.edition,ProgressMigration.courseEdition)
        XCTAssertTrue(loaded.unknownFields.isEmpty,"\(loaded.unknownFields)");XCTAssertTrue(loaded.unknownNestedFields.isEmpty,"\(loaded.unknownNestedFields)")
    }
    /// The tables were generated outside the app with the same function; this vector pins the two together.
    func testDigestMatchesTheTableGenerator() {
        XCTAssertEqual(ProgressMigration.digest("retired-a"),"1d4d5f500d51a121")
        XCTAssertEqual(ProgressMigration.digest("").count,16)
    }
    func testShippedTablesPointAtCurrentContent()throws {
        let library=try CourseLibrary(),ids=Set(library.lessons.map(\.id))
        XCTAssertEqual(ProgressMigration.lessons.count,25);XCTAssertEqual(ProgressMigration.miniGames.count,6)
        for (key,id) in ProgressMigration.lessons {XCTAssertTrue(key.range(of:"\\A[0-9a-f]{16}\\z",options:.regularExpression) != nil);XCTAssertTrue(ids.contains(id),id)}
        for (key,id) in ProgressMigration.miniGames {XCTAssertTrue(key.range(of:"\\A[0-9a-f]{16}\\z",options:.regularExpression) != nil);XCTAssertNotNil(MiniGameKind(rawValue:id),id)}
        // No current identifier is itself in a table, or migration would rename live progress.
        for id in ids.union(MiniGameKind.allCases.map(\.rawValue)) {XCTAssertNil(ProgressMigration.lessons[ProgressMigration.digest(id)],id);XCTAssertNil(ProgressMigration.miniGames[ProgressMigration.digest(id)],id)}
    }
}
