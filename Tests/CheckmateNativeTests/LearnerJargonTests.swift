import XCTest
@testable import CheckmateNative
import CheckmateCore
import CheckmateRules
@testable import CheckmateDomain
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// V-7: what the learner reads names no protocol, engine or service term: no MCP, model access, ply or half-move, and no
/// method name. Typed states and problems carry the plain words; the details go to the log.
final class LearnerJargonTests:XCTestCase {
    static let jargon=try! NSRegularExpression(pattern:#"\bMCP\b|model access|\bpl(y|ies)\b|half-moves?\b|\b(thread|account|turn|item|model|mcpServerStatus)/[a-zA-Z]+|\bRPC\b"#,options:[.caseInsensitive])
    /// A library's own name, which the learner reads as a name.
    static let allowed:Set<String>=["Swift MCP SDK and dependencies"]
    static func jargon(in text:String)->Bool {jargon.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil}

    /// Every phrase in a source file's string literals, except comments, log lines and automation checks. A literal with
    /// no space is a key, path or identifier, not something the learner reads.
    static func phrases(in file:URL)throws->[(line:Int,text:String)] {
        let literal=try NSRegularExpression(pattern:#""(?:[^"\\\n]|\\.)*""#),interpolation=try NSRegularExpression(pattern:#"\\\((?:[^()]|\([^()]*\))*\)"#)
        var found:[(Int,String)]=[]
        for (index,line) in try String(contentsOf:file,encoding:.utf8).components(separatedBy:"\n").enumerated() {
            let code=line.trimmingCharacters(in:.whitespaces)
            if code.hasPrefix("//") || line.contains("NativeLog.") || line.lowercased().contains("fixture") || line.contains("failures.append(") {continue}
            for match in literal.matches(in:line,range:NSRange(line.startIndex...,in:line)) {
                let raw=String(line[Range(match.range,in:line)!]),text=interpolation.stringByReplacingMatches(in:raw,range:NSRange(raw.startIndex...,in:raw),withTemplate:"")
                if text.contains(" "){found.append((index+1,String(text.dropFirst().dropLast())))}
            }
        }
        return found
    }
    private var root:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()}

    /// The app's own text, the modules whose messages it shows, and the broker's replies to a Codex task.
    func testLearnerTextSaysNoJargon()throws {
        let sources=root.appendingPathComponent("Sources")
        var files:[URL]=[]
        for module in ["CheckmateNative","CheckmateApplication","CheckmateContent"] {
            files+=try FileManager.default.contentsOfDirectory(at:sources.appendingPathComponent(module),includingPropertiesForKeys:nil).filter{$0.pathExtension=="swift"}
        }
        files+=[sources.appendingPathComponent("CheckmateMacPlatform/CompanionBroker.swift"),sources.appendingPathComponent("CheckmateMCPKit/BrokerClient.swift")]
        XCTAssertGreaterThan(files.count,40,"the scan found the sources")
        var offenders:[String]=[]
        for file in files {for (line,text) in try Self.phrases(in:file) where Self.jargon(in:text) && !Self.allowed.contains(text) {offenders.append("\(file.lastPathComponent):\(line): \(text)")}}
        XCTAssertEqual(offenders,[],"learner text with jargon")
    }
    /// The scan sees what it must: a literal with jargon is caught, while keys, comments and log lines are not read.
    func testTheScanCatchesJargon()throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".swift");defer{try? FileManager.default.removeItem(at:file)}
        try """
        Text("Turn on MCP first")
        let x=["plies":1]
        // The ply is a comment.
        NativeLog.voice.error("thread/start failed for \\(id)")
        Text("Game of \\(count) half-moves")
        """.write(to:file,atomically:true,encoding:.utf8)
        XCTAssertEqual(try Self.phrases(in:file).filter{Self.jargon(in:$0.text)}.map(\.line),[1,5])
    }
    /// R-24: the review's tactical patterns, game overview, opening line and retry live in a scanned module, and the
    /// text they build at run time is plain too.
    func testReviewPatternsAndOverviewSayNoJargon()throws {
        let sources=root.appendingPathComponent("Sources/CheckmateApplication")
        for name in ["ReviewMotifs.swift","ReviewExplanation.swift","OpeningBook.swift","ReviewRetry.swift"] {XCTAssertTrue(FileManager.default.fileExists(atPath:sources.appendingPathComponent(name).path),"\(name) is in a scanned module")}
        let document=try PGNImporter.parse(Data("1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0".utf8))[0]
        let losses:[[Int:Double]?]=[nil,[:],[document.mainline[5]:0.9]]
        var texts=try losses.map{try ReviewExplanation.make(document:document,node:0,losses:$0).summary}
        for (fen,uci) in [("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1","b5c7"),("4k3/8/2n5/8/8/8/8/4KB2 w - - 0 1","f1b5"),("4q3/8/8/4k3/8/8/8/R6K w - - 0 1","a1e1"),("4k3/8/3p4/8/8/5N2/8/4K3 w - - 0 1","f3e5"),("6k1/5ppp/8/8/8/8/P4PPP/R5K1 w - - 0 1","a1e1"),("7k/6q1/8/8/3N4/8/1B6/4K3 w - - 0 1","d4b5")] {
            let rules=try ChessRules(fen:fen),before=rules.board,move=try rules.move(uci:uci);texts+=ReviewMotifs.find(before:before,after:rules.board,from:move.from,to:move.to).map(\.text)
        }
        XCTAssertEqual(texts.count,9,"every pattern was found")
        // Retry mode's every message (R-18), for the learner's own game and for a game of others.
        let phases:[ReviewRetry.Phase]=[.trying(tries:0,last:nil),.trying(tries:1,last:.played("Nf5")),.trying(tries:1,last:.worse("Nf5")),.judging(tries:1),.solved("Nf5"),.revealed("Nf5"),.revealed(nil)]
        texts+=phases.flatMap{phase in [true,false].map{ReviewRetry.message(phase,played:"12… Nf5",mover:"b",own:$0)}}+[ReviewRetry.summary(solved:1,total:1),ReviewRetry.summary(solved:2,total:3)]
        for text in texts {XCTAssertFalse(Self.jargon(in:text),text)}
    }
    /// L-25: a finished mini-game's review reads as plain words, not as a search report: no forced or proved wins and no
    /// single moves, with the computer or the side named, for games against the computer and on one device alike.
    func testAMiniGameReviewSpeaksPlainly()throws {
        let search=try NSRegularExpression(pattern:#"\bforced?\b|\bprov(ed|en)\b|single moves?|\bopponent\b"#,options:[.caseInsensitive])
        func plain(_ text:String)->Bool {search.firstMatch(in:text,range:NSRange(text.startIndex...,in:text))==nil && !Self.jargon(in:text)}
        var texts=[MiniGameReviewWording.method,MiniGameReviewWording.running,MiniGameReviewWording.incomplete,MiniGameReviewWording.noFacts]
        for computer in [true,false] {
            var game=MiniGameState(kind:.rookSweep,computer:computer);game.snapshot.board=["a1":"wr","h2":"wp","e5":"br","a7":"bp"]
            for move in [("a1","b1"),("e5","h5"),("b1","b2"),("h5","h2")] {XCTAssertTrue(game.play(MiniGameMove(from:move.0,to:move.1)))}
            let review=MiniGameReview.run(game,cpuSeconds:{0},stop:{false});XCTAssertEqual(review.facts.count,computer ? 2:3,"\(review.facts.map(\.text))")
            texts+=review.facts.map(\.text)+[MiniGameReviewWording.summary(review)]
        }
        XCTAssertTrue(texts.contains("Move 1, a1–b1: after this move, Black could win in 2 moves, whatever White did."),"\(texts)")
        for text in texts {XCTAssertTrue(plain(text),text)}
    }
    /// Settings ▸ Connections shows the broker's typed state and problem; each is plain and distinct.
    @MainActor func testCompanionStatesAndProblemsArePlain() {
        let texts=CompanionState.allCases.map(\.text)+CompanionProblem.allCases.map(\.message)
        for text in texts {XCTAssertFalse(Self.jargon(in:text),text);XCTAssertFalse(text.isEmpty)}
        XCTAssertEqual(Set(texts).count,texts.count,"each state and problem has its own words")
        for failure in VoiceFailure.allCases {XCTAssertFalse(Self.jargon(in:failure.cause),failure.cause)}
    }
}
