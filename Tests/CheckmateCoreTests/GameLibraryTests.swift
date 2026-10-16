import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// The bundled game library: a strictly validated manifest whose every record replays to exactly what it states, and
/// the coverage the roster asks for.
final class GameLibraryTests:XCTestCase {
    private static let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The coverage gate (plan WI-9): every roster event has a bundled game, at least 150 in all, under 2 MB.
    func testCoverageGate() throws {
        let library=try GameLibrary.load()
        struct Roster:Decodable {struct Event:Decodable {let id:String};let events:[Event]}
        let roster=try JSONDecoder().decode(Roster.self,from:Data(contentsOf:Self.repository.appendingPathComponent("Content/game-library/roster.json")))
        XCTAssertEqual(library.events.map(\.id),roster.events.map(\.id))
        let covered=Set(library.games.compactMap(\.event))
        XCTAssertEqual(roster.events.map(\.id).filter{!covered.contains($0)},[],"Roster events without a bundled game")
        XCTAssertGreaterThanOrEqual(library.games.count,150)
        let bytes=try FileManager.default.contentsOfDirectory(at:GameLibrary.directory,includingPropertiesForKeys:[.fileSizeKey]).reduce(0){$0+((try $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
        XCTAssertLessThan(bytes,2*1024*1024)
    }
    func testEveryGameReplaysToItsManifestEntry() throws {
        let library=try GameLibrary.load()
        for game in library.games {
            let data=try library.data(game),report=try PGNImporter.parseReport(data,provenance:GameLibrary.provenance)
            XCTAssertTrue(report.skipped.isEmpty,game.id);XCTAssertEqual(report.documents.count,1,game.id)
            let d=try XCTUnwrap(report.documents.first)
            XCTAssertEqual(d.headers.map(\.name),["Event","Site","Date","Round","White","Black","Result"]+(game.opening==nil ? []:["ECO","Opening"]),game.id)
            XCTAssertEqual(d.header("Opening"),game.opening?.name,game.id);XCTAssertEqual(d.header("White"),game.white,game.id);XCTAssertEqual(d.header("Black"),game.black,game.id)
            XCTAssertTrue(d.nodes.allSatisfy{$0.commentsBefore.isEmpty && $0.commentsAfter.isEmpty && $0.nags.isEmpty && $0.children.count<=1},game.id)
            let line=d.mainline,last=try XCTUnwrap(line.last),final=d.nodes[last]
            XCTAssertEqual(line.count,game.plies,game.id);XCTAssertEqual(final.san,game.finalSAN,game.id)
            // The hash pins the exact moves, so a legal but different substitution fails.
            XCTAssertEqual(reviewHash(Data(line.compactMap{d.nodes[$0].uci}.joined(separator:" ").utf8)),game.uciSHA256,game.id)
            let rules=try d.rules(at:last);XCTAssertEqual(rules.checkmate,game.ending=="checkmate",game.id)
            XCTAssertEqual(d.result,game.result,game.id);XCTAssertEqual(game.ending=="draw",game.result=="1/2-1/2",game.id)
            if game.ending=="checkmate"{XCTAssertEqual(d.result,final.side=="w" ? "1-0":"0-1",game.id)}
            XCTAssertEqual(d.provenance,"Library game")
        }
    }
    func testTitlesAndRoundsAreGenerated() throws {
        let library=try GameLibrary.load()
        let game=try XCTUnwrap(library.games.first{$0.id=="wch-1886-1"})
        XCTAssertEqual(game.title,"Zukertort – Steinitz, World Championship 1886, Game 1");XCTAssertEqual(game.roundLabel,"Game 1")
        XCTAssertEqual(library.games.first{$0.id=="wch-2016-tiebreak-4"}?.roundLabel,"Tiebreak game 4")
        XCTAssertEqual(library.games.first{$0.id=="wch-1948-botvinnik-keres"}?.roundLabel,"Round 10")
        XCTAssertEqual(library.event("wch-1890")?.title,"World Championship 1890–91")
        // A source that dates a game of a two-year match by year alone gives no game year: the span is shown instead.
        let late=try XCTUnwrap(library.games.first{$0.id=="wch-1890-19"});XCTAssertNil(late.year);XCTAssertEqual(late.title,"Steinitz – Gunsberg, World Championship 1890–91, Game 19")
        XCTAssertEqual(library.games.first{$0.id=="wch-1886-1"}?.year,1886)
        XCTAssertEqual(Set(library.games.filter{$0.category=="classic"}.map(\.id)),["immortal","evergreen","legal-mate","lasker-thomas","steinitz-bardeleben","rotlewi-rubinstein","levitsky-marshall","byrne-fischer","kasparov-topalov","capablanca-marshall","botvinnik-capablanca","polugaevsky-nezhmetdinov","short-timman","deep-blue-kasparov"])
    }
    // MARK: Validation: each rejection, on a copy of the bundle
    private func copy()throws -> (URL,String) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("game-library-\(UUID().uuidString)");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for name in try FileManager.default.contentsOfDirectory(atPath:GameLibrary.directory.path){try FileManager.default.copyItem(at:GameLibrary.directory.appendingPathComponent(name),to:folder.appendingPathComponent(name))}
        return (folder,try String(contentsOf:folder.appendingPathComponent("manifest.json"),encoding:.utf8))
    }
    private func rejects(_ folder:URL,_ manifest:String,_ change:(String)->String,_ message:String,file:StaticString=#filePath,line:UInt=#line) throws {
        let changed=change(manifest);XCTAssertNotEqual(changed,manifest,"The mutation did not apply: "+message,file:file,line:line)
        try changed.write(to:folder.appendingPathComponent("manifest.json"),atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try GameLibrary.load(from:folder),message,file:file,line:line)
    }
    func testABrokenManifestFailsLoudly() throws {
        let (folder,manifest)=try copy();defer{try? FileManager.default.removeItem(at:folder)}
        XCTAssertEqual(try GameLibrary.load(from:folder).games,try GameLibrary.load().games)
        func first(_ pattern:String,_ replacement:String)->(String)->String {{text in guard let range=text.range(of:pattern,options:.regularExpression) else{return text};return text.replacingCharacters(in:range,with:replacement)}}
        try rejects(folder,manifest,first(#""file": "world-championship.pgn""#,#""file": "../world-championship.pgn""#),"A file outside the folder is accepted")
        try rejects(folder,manifest,first(#""file": "world-championship.pgn""#,#""file": "classic.pgn""#),"A file of another category is accepted")
        try rejects(folder,manifest,first(#""kind": "game""#,#""kind": "legend""#),"An unknown kind is accepted")
        try rejects(folder,manifest,first(#""ending": "unknown""#,#""ending": "resignation-ish""#),"An unknown ending is accepted")
        try rejects(folder,manifest,first(#""result": "0-1""#,#""result": "0-2""#),"An unknown result is accepted")
        try rejects(folder,manifest,first(#""id": "wch-1886-7""#,#""id": "wch-1886-1""#),"A duplicate id is accepted")
        try rejects(folder,manifest,first(#""id": "wch-1886-7""#,#""id": "../x""#),"An id that is not a plain identifier is accepted")
        try rejects(folder,manifest,first(#""event": "wch-1886""#,#""event": "wch-1999""#),"A game of an unknown event is accepted")
        try rejects(folder,manifest,first(#""plies": \d+"#,"\"plies\": \(Int.max)"),"A ply count beyond the review limit is accepted")
        try rejects(folder,manifest,first(#""offset": 0"#,"\"offset\": \(Int.max)"),"An offset beyond the file is accepted")
        try rejects(folder,manifest,first(#""length": \d+"#,"\"length\": 99999999"),"A length beyond the file is accepted")
        try rejects(folder,manifest,first(#""sha256": "[0-9a-f]{64}""#,#""sha256": "abc""#),"A malformed record hash is accepted")
        try rejects(folder,manifest,first(#""title": "[^"]*""#,"\"title\": \""+String(repeating:"x",count:300)+"\""),"An unbounded title is accepted")
        try rejects(folder,manifest,first(#""schemaVersion": 1"#,#""schemaVersion": 2"#),"An unknown schema is accepted")
        try rejects(folder,manifest,first(#""offset": 0,"#,#""offset": 1,"#),"A range that leaves bytes unreferenced is accepted")
        try rejects(folder,manifest,first(#""world-championship": \d+"#,#""world-championship": 999"#),"A wrong category count is accepted")
        // One game left out of the manifest: its bytes are unreferenced and the count no longer agrees.
        try rejects(folder,manifest,{text in guard let start=text.range(of:#"\{\s*"id": "wch-1886-7""#,options:.regularExpression)?.lowerBound,let end=text.range(of:"},",range:start..<text.endIndex)?.upperBound else{return text};return text.replacingCharacters(in:start..<end,with:"")},"An omitted manifest entry is accepted")
        // A whole category left out, its count set to 0: its file is no longer referenced, and that is refused.
        try rejects(folder,manifest,{text in
            guard var object=try? JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],var counts=object["counts"] as? [String:Any],let games=object["games"] as? [[String:Any]] else{return text}
            counts["classic"]=0;object["counts"]=counts;object["games"]=games.filter{$0["category"] as? String != "classic"}
            return (try? JSONSerialization.data(withJSONObject:object)).flatMap{String(data:$0,encoding:.utf8)} ?? text
        },"An omitted category is accepted")
        try manifest.write(to:folder.appendingPathComponent("manifest.json"),atomically:true,encoding:.utf8)
        try Data("[Event \"x\"]\n".utf8).write(to:folder.appendingPathComponent("extra.pgn"))
        XCTAssertThrowsError(try GameLibrary.load(from:folder),"An unreferenced PGN file is accepted")
        try FileManager.default.removeItem(at:folder.appendingPathComponent("extra.pgn"))
        try FileManager.default.removeItem(at:folder.appendingPathComponent("classic.pgn"))
        XCTAssertThrowsError(try GameLibrary.load(from:folder),"A missing category file is accepted")
    }
    /// A record changed in place (same length) is refused when opened; a parsed game that differs from its entry is refused.
    func testACorruptedRecordFailsWhenOpened() throws {
        let (folder,_)=try copy();defer{try? FileManager.default.removeItem(at:folder)}
        var bytes=try Data(contentsOf:folder.appendingPathComponent("classic.pgn"));bytes[bytes.count-3]=UInt8(ascii:"9");try bytes.write(to:folder.appendingPathComponent("classic.pgn"))
        let intact=try GameLibrary.load(),last=try XCTUnwrap(intact.games.last)
        XCTAssertThrowsError(try GameLibrary.load(from:folder).data(last))
        XCTAssertNoThrow(try intact.data(last))
        let game=try XCTUnwrap(intact.games.first{$0.id=="wch-1886-1"}),other=try XCTUnwrap(intact.games.first{$0.id=="wch-1886-7"})
        let document=try XCTUnwrap(PGNImporter.parseReport(intact.data(game),provenance:GameLibrary.provenance).documents.first)
        XCTAssertNoThrow(try GameLibrary.verify(document,matches:game))
        XCTAssertThrowsError(try GameLibrary.verify(document,matches:other))
    }
}
