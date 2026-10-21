import XCTest
@testable import CheckmateNative
import CheckmateCore
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
    /// Settings ▸ Connections shows the broker's typed state and problem; each is plain and distinct.
    @MainActor func testCompanionStatesAndProblemsArePlain() {
        let texts=CompanionState.allCases.map(\.text)+CompanionProblem.allCases.map(\.message)
        for text in texts {XCTAssertFalse(Self.jargon(in:text),text);XCTAssertFalse(text.isEmpty)}
        XCTAssertEqual(Set(texts).count,texts.count,"each state and problem has its own words")
        for failure in VoiceFailure.allCases {XCTAssertFalse(Self.jargon(in:failure.cause),failure.cause)}
    }
}
