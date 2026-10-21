import XCTest
import CheckmateCore

/// Shown text goes through the String Catalog (D-11): a literal that reads as English prose must reach the screen through
/// `String(localized:…,bundle:.checkmate)` or a SwiftUI text initializer, and developer text (preconditions, logs, PGN tags,
/// model prompts, wire values) must not be put into the catalog. A deliberate exception carries `// not localized: <reason>`.
@MainActor final class LocalizationLintTests:XCTestCase {
    private static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),sources=root.appendingPathComponent("Sources")
    /// The sources the published calibration results were played from: a change to one invalidates its results, so their
    /// text waits for the next calibration on the test host.
    private func calibrated()throws->Set<String> {
        struct Recorded:Decodable {struct Identity:Decodable {let sourceSHA256:[String:String]};let identity:Identity}
        let paths=try ["mini-game-results.json","position-game-results.json"].flatMap{try JSONDecoder().decode(Recorded.self,from:Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/"+$0))).identity.sourceSHA256.keys}
        let sources=Set(paths.filter{$0.hasPrefix("Sources/")}.map{String($0.dropFirst("Sources/".count))});XCTAssertGreaterThan(sources.count,5,"the calibration results name their sources");return sources
    }
    /// Developer tooling and machine-facing files: the MCP server and engine, tool schemas and automation fixtures.
    private static let skippedTargets:Set<String>=["CheckmateMCP","CheckmateMCPKit","CheckmateEngine"]
    private static let skippedFiles:Set<String>=["CheckmateNative/LayoutAcceptance.swift","CheckmateNative/LessonAutomationFixture.swift","CheckmateCore/Assets.swift","CheckmateSupport/ToolSchemas.swift","CheckmateSupport/ProtocolErrors.swift","CheckmateApplication/CompanionTools.swift","CheckmateApplication/ReviewTools.swift","CheckmateApplication/ReviewVoice.swift","CheckmateApplication/TrainingTools.swift","CheckmateApplication/TrainingVoiceAdapter.swift"]

    func testTheLintCatchesShownTextAndSparesDeveloperText() {
        let lint=LocalizationLint()
        func hits(_ code:String)->[String] {lint.analyse(code).hits.map(\.text)}
        XCTAssertEqual(hits(#"label.stringValue="Something went wrong""#),["Something went wrong"])
        XCTAssertEqual(hits(#"Text(flag ? "Hello there":"Bye now")"#),["Hello there","Bye now"])
        XCTAssertEqual(hits(#"alert.messageText="A game is open""#),["A game is open"])
        XCTAssertEqual(hits(#"parts.append("in your answer")"#),["in your answer"])
        XCTAssertEqual(hits("let x=compute(\n  \"Shown later\")"),["Shown later"])
        XCTAssertEqual(hits(#"let x=String(localized:"Hello there",bundle:.checkmate)"#),[])
        XCTAssertEqual(hits(#"Text("Hello there");Button("Open Game"){}"#),[])
        XCTAssertEqual(hits(#"let event=d.header("Event")"#),[])
        XCTAssertEqual(hits(#"precondition(ok,"The state is broken")"#),[])
        XCTAssertEqual(hits(#"NativeLog.network.info("Peer went away")"#),[])
        XCTAssertEqual(hits(#"if title=="Open Game"{}"#),[])
        XCTAssertEqual(hits(#"let wire="Not shown here" // not localized: wire value"#),[])
        XCTAssertEqual(hits("case gentle=\"Gentle Play\""),[])
        XCTAssertEqual(hits("let s=\"\"\"\nSome text here\n\"\"\""),[])
        XCTAssertEqual(hits(#"let m=["Some key":1]"#),[])
        XCTAssertEqual(hits(#"let id="board-square""#),[])
        XCTAssertEqual(lint.analyse(#"precondition(ok,String(localized:"The state is broken",bundle:.checkmate))"#).misplaced,[1])
    }

    func testShownTextGoesThroughTheCatalog()throws {
        let files=try XCTUnwrap(FileManager.default.enumerator(at:Self.sources,includingPropertiesForKeys:nil)).compactMap{$0 as? URL}.filter{$0.pathExtension=="swift"}
        XCTAssertGreaterThan(files.count,50,"the scan found the sources")
        let lint=LocalizationLint(),calibrated=try calibrated();var scanned=0,bypassing:[String]=[],misplaced:[String]=[]
        for url in files {
            let file=String(url.path.dropFirst(Self.sources.path.count+1))
            guard !Self.skippedTargets.contains(String(file.prefix{$0 != "/"})),!Self.skippedFiles.contains(file),!calibrated.contains(file) else{continue}
            let found=lint.analyse(try String(contentsOf:url,encoding:.utf8));scanned+=found.literals
            bypassing+=found.hits.map{"\(file):\($0.line) \($0.text)"};misplaced+=found.misplaced.map{"\(file):\($0)"}
        }
        XCTAssertGreaterThan(scanned,5000,"the lint saw the app's literals")
        XCTAssertEqual(bypassing,[],"shown text: use String(localized:…,bundle:.checkmate), or mark developer text with // not localized: <reason>")
        XCTAssertEqual(misplaced,[],"developer text (a precondition, log or tag) is not shown: keep it out of the String Catalog")
    }

    func testTheCatalogShipsEnglish() {
        XCTAssertTrue(Bundle.checkmate.localizations.contains("en"),"the resource bundle carries the compiled String Catalog")
        XCTAssertEqual(String(localized:"\(1) moves",bundle:.checkmate),"1 move")
    }
}

/// A whole-file scan of Swift string literals that tracks the call each literal is an argument of, so a call spanning
/// lines keeps its callee. Comments, multi-line strings and raw strings are skipped.
private struct LocalizationLint {
    final class Frame {
        let callee:String,start:Int;var label:String?,argumentStart:Int,end:Int?
        init(callee:String,start:Int,argumentStart:Int){self.callee=callee;self.start=start;self.argumentStart=argumentStart}
    }
    /// A frame as it stood at one literal: its label then, and its end once the scan closes it.
    struct Snapshot {let frame:Frame,label:String?;var callee:String {frame.callee}}
    struct Literal {let start:Int,end:Int,text:String,stack:[Snapshot],prefix:String}
    enum Kind {case localized,developer,swiftUI}

    private let prose=try! NSRegularExpression(pattern:#"^[\W\x{01}]*(?:[A-Z](?:[a-z’']+(?:$|[ ,.…?!:;\x{01}’'])| [a-z])|[a-z][a-z’']* [a-z’']+ [a-z])"#)
    private let swiftUI:Set<String>=["Text","Button","Toggle","Label","Picker","Section","Menu","LabeledContent","GroupBox","TextField","SecureField","Link","DisclosureGroup","ProgressView","Stepper","ControlGroup","Tab",".help",".accessibilityLabel",".accessibilityHint",".accessibilityValue",".navigationTitle",".alert",".confirmationDialog",".value"]
    private let developerCallees:Set<String>=["print","NSLog","fatalError","precondition","preconditionFailure","assert","assertionFailure","Logger","appendingPathComponent","appendingPathExtension","NSUserInterfaceItemIdentifier","Notification.Name","header","known","tag","PGNHeader","ProtocolFailure","setAccessibilityIdentifier","accessibilityIdentifier","identifier","hasPrefix","hasSuffix","contains","starts","components","firstIndex","lastIndex","split","range"]
    private let developerLabels:Set<String>=["fileURLWithPath","forKey","path","forHTTPHeaderField","debugDescription","instructions","comment","identifier","withIdentifier","systemName","systemImage","systemSymbolName","named","forResource","withExtension","ofType"]
    private let marker=try! NSRegularExpression(pattern:#"//.*\bnot localized\b"#)
    private let member=try! NSRegularExpression(pattern:#"^    (?:@\w+ )*(?:private |static |public |override |nonisolated )*(?:func|var|let|init)\b"#)
    private let scenario=try! NSRegularExpression(pattern:#"^    (?:@\w+ )*(?:private |static |public )*func (run\w*)\b"#)

    private func first(_ regex:NSRegularExpression,_ text:String)->NSTextCheckingResult? {regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text))}
    private func has(_ pattern:String,_ text:String)->Bool {first(try! NSRegularExpression(pattern:pattern),text) != nil}
    private static func isIdentifier(_ c:Character)->Bool {c.isLetter || c.isNumber || c=="_" || c=="."}

    func scan(_ s:[Character])->[Literal] {
        let n=s.count;var i=0,stack:[Frame]=[],out:[Literal]=[]
        func starts(_ p:String,_ at:Int)->Bool {let p=Array(p);return at+p.count<=n && Array(s[at..<at+p.count])==p}
        func find(_ p:String,_ from:Int)->Int? {var k=from;while k<n {if starts(p,k){return k};k+=1};return nil}
        func label(_ at:Int)->String? {
            var k=at;while k<n,s[k].isWhitespace{k+=1};let a=k;while k<n,s[k].isLetter || s[k].isNumber || s[k]=="_"{k+=1};guard k>a else{return nil}
            let word=String(s[a..<k]);while k<n,s[k].isWhitespace{k+=1};guard k<n,s[k]==":",!(k+1<n && s[k+1]==":") else{return nil};return word
        }
        while i<n {
            let c=s[i]
            if starts("//",i){i=find("\n",i) ?? n;continue}
            if starts("/*",i){i=find("*/",i).map{$0+2} ?? n;continue}
            if starts("\"\"\"",i){i=find("\"\"\"",i+3).map{$0+3} ?? n;continue}
            if starts("#\"",i){i=find("\"#",i+2).map{$0+2} ?? n;continue}
            if c=="\"" {
                let start=i;i+=1;var parts=""
                while i<n,s[i] != "\"",s[i] != "\n" {
                    if starts("\\(",i){
                        var depth=1;i+=2
                        while i<n,depth>0 {
                            if s[i]=="("{depth+=1}else if s[i]==")"{depth-=1}
                            else if s[i]=="\""{i+=1;while i<n,s[i] != "\""{i+=s[i]=="\\" ? 2:1}}
                            i+=1
                        }
                        parts.append("\u{1}");continue
                    }
                    if s[i]=="\\"{parts+=String(s[i..<min(i+2,n)]);i+=2;continue}
                    parts.append(s[i]);i+=1
                }
                let prefix=stack.last.map{String(s[$0.argumentStart..<start])} ?? ""
                out.append(Literal(start:start,end:min(i+1,n),text:parts,stack:stack.map{Snapshot(frame:$0,label:$0.label)},prefix:prefix));i+=1;continue
            }
            if c=="(" {
                var k=i;while k>0,Self.isIdentifier(s[k-1]){k-=1}
                let frame=Frame(callee:String(s[k..<i]),start:k,argumentStart:i+1);frame.label=label(i+1);stack.append(frame);i+=1;continue
            }
            if c==")" {if let frame=stack.popLast(){frame.end=i+1};i+=1;continue}
            if c==",",let frame=stack.last {frame.argumentStart=i+1;frame.label=label(i+1)}
            i+=1
        }
        return out
    }

    func kind(_ frame:Snapshot?)->Kind? {
        guard let frame else{return nil}
        let callee=frame.callee,last=String(callee.split(separator:".").last ?? "")
        if callee=="String" && frame.label=="localized" || ["LocalizedStringResource","LocalizedStringKey","String.LocalizationValue"].contains(callee){return .localized}
        if callee.hasPrefix("NativeLog.") || developerCallees.contains(callee) || developerCallees.contains(last) && callee.contains(".") || frame.label.map({developerLabels.contains($0)}) == true || callee=="NSFont" && frame.label=="name" {return .developer}
        if (swiftUI.contains(callee) || callee.hasPrefix(".") && swiftUI.contains("."+last)) && frame.label==nil {return .swiftUI}
        return nil
    }

    /// Whether a literal needs no catalog entry: it is already localized, or it is compared, matched, a raw value or a key.
    func isAccountedFor(_ s:[Character],_ literal:Literal)->Bool {
        switch kind(literal.stack.last){
        case .localized?,.developer?:return true
        case .swiftUI?:if literal.prefix.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{return true}
        case nil:break
        }
        var a=literal.start;while a>0,s[a-1] != "\n"{a-=1};var b=literal.end;while b<s.count,s[b] != "\n"{b+=1}
        let before=String(s[a..<literal.start]),after=String(s[literal.end..<b])
        if has(#"[=!]=\s*$"#,before) || has(#"^\s*[=!]="#,after){return true}
        if has(#"\bcase\s*$"#,before) || has(#"\bcase\b[^:]*,\s*$"#,before) && !(before.components(separatedBy:"case").last ?? "").contains("return"){return true}
        if before.drop(while:{$0.isWhitespace}).hasPrefix("case ") && has(#"(?:\bcase|,)\s*\w+\s*=\s*$"#,before){return true}
        return has(#"[\[,]\s*$"#,before) && has(#"^\s*:"#,after)
    }

    /// Scenario code in automation runs only under `--automation`; its text is evidence, not shown to a learner.
    func excludedLines(_ lines:[String])->Set<Int> {
        var automation=false,out:Set<Int>=[]
        for (index,line) in lines.enumerated() {
            if first(member,line) != nil {
                let name=first(scenario,line).flatMap{Range($0.range(at:1),in:line).map{String(line[$0])}}
                automation=name.map{$0.hasSuffix("Scenario") || $0=="runFullscreen"} ?? false
            }
            if automation || first(marker,line) != nil {out.insert(index+1)}
        }
        return out
    }

    /// Prose literals that bypass the catalog, and the lines where developer text was put into it.
    func analyse(_ text:String)->(literals:Int,hits:[(line:Int,text:String)],misplaced:[Int]) {
        let s=Array(text),lines=text.components(separatedBy:"\n");var lineStarts=[0]
        for line in lines {lineStarts.append(lineStarts.last!+line.count+1)}
        func lineOf(_ offset:Int)->Int {var low=0,high=lineStarts.count;while low<high {let mid=(low+high)/2;if lineStarts[mid]<=offset{low=mid+1}else{high=mid}};return low}
        let skipped=excludedLines(lines),literals=scan(s);var hits:[(line:Int,text:String)]=[],misplaced:[Int]=[]
        for literal in literals {
            let line=lineOf(literal.start)
            guard !skipped.contains(line),first(prose,literal.text) != nil else{continue}
            if !isAccountedFor(s,literal){hits.append((line,literal.text));continue}
            guard let frame=literal.stack.last,frame.callee=="String",kind(frame) == .localized,literal.stack.count>1,kind(literal.stack[literal.stack.count-2]) == .developer,let end=frame.frame.end,s[frame.frame.start..<end].filter({$0=="\""}).count==2 else{continue}
            misplaced.append(line)
        }
        return (literals.count,hits,misplaced)
    }
}
