import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// B10 review findings RV2-4, RV2-6, RV2-7 and RV2-2a: import limits that cost little, games that read back from their
/// own text, exports that re-import as written, and a re-parse skipped only for what the importer itself built.
final class B10ReviewImportTests:XCTestCase {
    func testACollectionOverTheGameLimitIsRefusedBeforeAnyGameIsBuilt(){
        // The token count that runs before the first game refuses it; the in-loop backstop said "Too many game records."
        // only after building 1000 games.
        XCTAssertThrowsError(try PGNImporter.parse(Data(String(repeating:"*\n",count:ReviewPolicy.maximumRecords+1).utf8))){error in
            // The limit is the file's, so the refusal names no record or token, and its count is formatted for the
            // reader's locale, as "1,000" in English.
            let problem=error as? ReviewImportError;XCTAssertNil(problem?.record)
            XCTAssertEqual(userFacingMessage(error,fallback:"?"),"The file has more than \(ReviewPolicy.maximumRecords.formatted()) games; split it into smaller files.")
        }
    }
    /// A refusal of the whole file (its size, its emptiness, or a collection's game count) is not located at a record
    /// and token, while a problem inside a game still is.
    func testAFileLevelRefusalNamesNoRecordOrToken(){
        func refusal(_ attempt:()throws->Void)->String? {do{try attempt();return nil}catch{return userFacingMessage(error,fallback:"?")}}
        XCTAssertEqual(refusal{_ = try PGNImporter.parseReport(Data(" \n".utf8))},"The file is empty.")
        XCTAssertEqual(refusal{_ = try PGNImporter.parseReport(Data(count:ReviewPolicy.maximumBytes+1))},"File exceeds the 16 MiB limit.")
        XCTAssertEqual(refusal{_ = try PGNImporter.splitRecords(Data(count:ReviewPolicy.maximumBytes+1),maximumRecords:3)},"File exceeds the 16 MiB limit.")
        let games=(1...1_001).map{"[White \"W\($0)\"]\n\n1. e4 *"}.joined(separator:"\n\n")
        XCTAssertEqual(refusal{_ = try PGNImporter.splitRecords(Data(games.utf8),maximumRecords:1_000)},"The file has more than 1,000 games.")
        XCTAssertEqual(refusal{_ = try PGNImporter.parse(Data("1. e9 *".utf8))}?.hasPrefix("Record 1, token "),true,"a problem inside a game keeps its place")
    }
    func testALexicalErrorEndsTheCountWithoutRefusingTheFile()throws {
        let report=try PGNImporter.parseReport(Data("[Event \"A\"]\n1. e4 *\n\n[Event \"B\"]\n1. d4 {never closed".utf8))
        XCTAssertEqual(report.documents.map(\.title),["A"]);XCTAssertEqual(report.skipped.count,1)
    }
    func testEmptyVariationsAndManyHeadersStillImport()throws {
        let variations=try PGNImporter.parse(Data(("1. e4 "+String(repeating:"() ",count:3000)+"e5 *").utf8))[0]
        XCTAssertEqual(variations.nodes.compactMap(\.san),["e4","e5"])
        let headers=(0..<5000).map{"[Tag\($0) \"v\"]"}.joined(separator:"\n")
        XCTAssertEqual(try PGNImporter.parse(Data((headers+"\n1. e4 *").utf8))[0].headers.count,5000)
    }
    func testAGameWithADuplicateHeaderIsSkippedWhole()throws {
        let report=try PGNImporter.parseReport(Data("[Event \"Bad\"]\n1. e5 *\n\n[Event \"Twice\"]\n[Event \"Again\"]\n1. e4 *\n\n[Event \"Good\"]\n1. d4 *".utf8))
        XCTAssertEqual(report.documents.map(\.title),["Good"],"The rest of the broken game must not import as a game of its own")
        XCTAssertEqual(report.skipped.map(\.record),[1,2],"Record numbers count skipped games")
    }
    func testEveryGameReadsBackFromItsOwnText()throws {
        // A saved review is re-read from its stored text, so commentary before a game must be part of that text.
        let report=try PGNImporter.parseReport(Data("{Annotated collection}\n[Event \"A\"]\n1. e4 {x} *\n{Between games}\n[Event \"B\"]\n1. d4 *\n{The end}".utf8))
        XCTAssertEqual(report.documents.map{$0.nodes[0].commentsBefore},[["Annotated collection"],["Between games"]])
        for document in report.documents{XCTAssertEqual(try document.rederived(),document,document.title)}
        let afterBadGame=try PGNImporter.parseReport(Data("[Event \"Bad\"]\n1. e5 *\n\n[Event \"Good\"]\n1. e4 *".utf8)).documents[0]
        XCTAssertEqual(afterBadGame.original,Data("[Event \"Good\"]\n1. e4 *".utf8),"A skipped game is not part of the next game's text")
        XCTAssertEqual(try afterBadGame.rederived(),afterBadGame)
    }
    func testALexicalErrorAfterAGameNeverCostsThatGame()throws {
        // Reading past game B's result meets game C's broken header; that is C's problem, reported under C's number.
        let report=try PGNImporter.parseReport(Data("[Event \"A\"]\n1. e4 *\n\n[Event \"B\"]\n1. d4 *\n\n[Event \"C".utf8))
        XCTAssertEqual(report.documents.map(\.title),["A","B"]);XCTAssertEqual(report.skipped.map(\.record),[3])
        XCTAssertEqual(report.documents[1].original,Data("[Event \"B\"]\n1. d4 *".utf8));XCTAssertEqual(try report.documents[1].rederived(),report.documents[1])
        // When game B fails on its own as well, both problems are reported, each under its own game.
        let both=try PGNImporter.parseReport(Data("[Event \"A\"]\n1. e4 *\n\n[Event \"B\"]\n[Result \"1-0\"]\n1. d4 0-1\n\n[Event \"C".utf8))
        XCTAssertEqual(both.documents.map(\.title),["A"]);XCTAssertEqual(both.skipped.map(\.record),[2,3])
    }
    /// `validate()` no longer re-parses what the importer built, so the corpus's read-back guarantee is checked here.
    func testEveryCorpusGameReadsBackFromItsOwnText()throws {
        let root=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_CORPUS"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/GameReview");var checked=0
        for file in ["manifest.json","manifest-expanded.json","manifest-novice.json"] {
            let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(file))) as? [String:Any])
            for entry in try XCTUnwrap(manifest["entries"] as? [[String:Any]]) where entry["expectedImport"] as? String != "reject" {
                let path=try XCTUnwrap(entry["path"] as? String)
                for document in try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent(path))){XCTAssertEqual(try document.rederived(),document,path);checked+=1}
            }
        }
        XCTAssertGreaterThanOrEqual(checked,60,"The corpus was found and read")
    }
    func testAFENOnlyReviewExportsWithoutASpuriousGame()throws {
        let position=try PGNImporter.parse(Data("8/8/8/4k3/8/8/8/4K2R w K - 0 1".utf8))[0];var idea=ReviewBranch(root:0);idea.moves=["e1f2"]
        let records=try PGNImporter.parse(PGNExporter.withIdeas(position,branches:[idea]))
        XCTAssertEqual(records.count,1,"One record from the position, with no extra empty game")
        // A position has no move to vary, so the imagined line is its record's moves, marked as imagined.
        XCTAssertEqual(records[0].startingFEN,position.startingFEN);XCTAssertEqual(records[0].nodes.count,2)
        XCTAssertEqual(try records[0].history(to:try XCTUnwrap(records[0].mainline.last)),["e1f2"]);XCTAssertEqual(records[0].nodes[0].commentsBefore,[PGNExporter.imaginedMarker],"A comment before the first move belongs to the position")
    }
    func testOnlyWhatTheImporterBuiltSkipsTheReParse()throws {
        let document=try PGNImporter.parse(Data("1. e4 {note} e5 *".utf8))[0]
        XCTAssertTrue(ImportedDocuments.shared.built(document));XCTAssertNoThrow(try document.validate())
        XCTAssertTrue(ImportedDocuments.shared.built(try JSONDecoder().decode(GameDocument.self,from:JSONEncoder().encode(document))),"An equal decoded copy is the same value")
        let n=document.nodes[1];var nodes=document.nodes
        nodes[1]=GameNode(id:n.id,parent:n.parent,children:n.children,uci:n.uci,san:n.san,beforeFEN:n.beforeFEN,afterFEN:n.afterFEN,ply:n.ply,fullmove:n.fullmove,side:n.side,commentsBefore:[],commentsAfter:["forged"],nags:n.nags)
        let forged=GameDocument(schemaVersion:1,id:document.id,contentHash:document.contentHash,importedAt:document.importedAt,provenance:document.provenance,original:document.original,headers:document.headers,startingFEN:document.startingFEN,result:document.result,termination:document.termination,historyAvailable:document.historyAvailable,nodes:nodes)
        XCTAssertFalse(ImportedDocuments.shared.built(forged));XCTAssertThrowsError(try forged.validate())
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        XCTAssertThrowsError(try ReviewStore(directory:root).save(forged,cursor:0,branches:[]),"A tree that is not its text's reading is never saved")
    }
}
