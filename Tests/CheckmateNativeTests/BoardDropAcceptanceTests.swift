import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore

/// The board takes a drag only when it carries a game record: one .pgn or .fen file, or text that reads as PGN or FEN.
/// Anything else is refused as it enters, so the board never offers to take what it cannot import.
@MainActor final class BoardDropAcceptanceTests:XCTestCase {
    private var pasteboard:NSPasteboard!
    override func setUp(){pasteboard=NSPasteboard(name:NSPasteboard.Name("checkmate-drop-\(UUID().uuidString)"));pasteboard.clearContents()}
    override func tearDown(){pasteboard.releaseGlobally()}
    func testRecordTextIsRecognised(){
        for text in ["[Event \"Casual\"]\n1. e4 e5 *","1. e4 e5 2. Nf3 *","1.d4 d5","  1... e5 2. Nf3","rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1","8/8/8/8/8/8/8/K6k w - -"] {
            XCTAssertTrue(ReviewDrop.looksLikeRecord(text),text)
        }
        for text in ["","   ","hello world","https://example.com/game.pgn","1. Buy milk","[link](x)","rnbqkbnr/pppppppp/8 w"] {
            XCTAssertFalse(ReviewDrop.looksLikeRecord(text),text)
        }
    }
    func testOnlyARecordFileOrRecordTextIsAccepted(){
        let directory=FileManager.default.temporaryDirectory
        func files(_ names:[String])->Bool {pasteboard.clearContents();pasteboard.writeObjects(names.map{directory.appendingPathComponent($0) as NSURL});return ReviewDrop.accepts(pasteboard)}
        XCTAssertTrue(files(["game.pgn"]));XCTAssertTrue(files(["position.FEN"]),"the extension is matched without case")
        XCTAssertFalse(files(["notes.txt"]),"a file of another kind is refused");XCTAssertFalse(files(["photo.png"]))
        XCTAssertFalse(files(["a.pgn","b.pgn"]),"one record file at a time")
        func text(_ string:String)->Bool {pasteboard.clearContents();pasteboard.setString(string,forType:.string);return ReviewDrop.accepts(pasteboard)}
        XCTAssertTrue(text("1. e4 e5 *"));XCTAssertFalse(text("Just a sentence."))
        pasteboard.clearContents();pasteboard.writeObjects([URL(string:"https://example.com/game.pgn")! as NSURL])
        XCTAssertFalse(ReviewDrop.accepts(pasteboard),"a web link is not a file")
    }
}
