import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore

/// Structure and strings: one symbol table, title-case commands, no display text used as logic, and the shared metrics.
@MainActor final class StructureStringsTests:XCTestCase {
    private static let sources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    /// Every Swift source line, with its file's path relative to `Sources`.
    private func sourceLines()throws->[(file:String,line:Int,text:String)] {
        let files=try XCTUnwrap(FileManager.default.enumerator(at:Self.sources,includingPropertiesForKeys:nil)).compactMap{$0 as? URL}.filter{$0.pathExtension=="swift"}
        XCTAssertGreaterThan(files.count,50,"the scan found the sources")
        return try files.flatMap{url in try String(contentsOf:url,encoding:.utf8).components(separatedBy:"\n").enumerated().map{(String(url.path.dropFirst(Self.sources.path.count+1)),$0.offset+1,$0.element)}}
    }
    private func matches(_ pattern:String,_ text:String)->[String] {
        let regex=try! NSRegularExpression(pattern:pattern)
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).map{m in String(text[Range(m.range(at:m.numberOfRanges>1 ? 1:0),in:text)!])}
    }
    func testEverySymbolResolvesAndOnlyTheTableNamesSymbols()throws {
        for symbol in AppSymbol.allCases {XCTAssertNotNil(symbol.nsImage(),symbol.rawValue)}
        let strays=try sourceLines().filter{!$0.file.hasSuffix("AppSymbol.swift") && !matches(#"(?:systemName|systemSymbolName|systemImage):\s*""#,$0.text).isEmpty}
        XCTAssertEqual(strays.map{"\($0.file):\($0.line)"},[],"name the meaning through AppSymbol instead of a symbol string")
    }
    /// Buttons and menu items use title case; labels and captions stay sentence case and are not checked here (D-15).
    func testButtonAndMenuTitlesUseTitleCase()throws {
        let minor:Set<String>=["a","an","and","as","at","but","by","for","from","in","into","of","on","or","the","to","with","vs"]
        func offending(_ title:String)->String? {
            let words=matches(#"[A-Za-z][A-Za-z'’]*"#,title)
            for (i,word) in words.enumerated() where !(word.first!.isUppercase || word.dropFirst().contains{$0.isUppercase}) {
                if minor.contains(word) && i>0 && i<words.count-1 {continue}
                return word
            }
            return nil
        }
        XCTAssertNil(offending("Set Up Codex"));XCTAssertNil(offending("Export Saved File…"));XCTAssertEqual(offending("Return to game"),"game");XCTAssertEqual(offending("Practise here"),"here")
        var checked=0,failures:[String]=[]
        for line in try sourceLines() {for title in matches(#"(?:\bButton|\bMenu|NSMenuItem\(title:|withTitle:|NSButton\(title:|\baction:)\(?"([^"\\]+)""#,line.text) {
            checked+=1;if let word=offending(title){failures.append("\(line.file):\(line.line) \(title) (\(word))")}
        }}
        XCTAssertGreaterThan(checked,100,"the lint saw the app's commands")
        XCTAssertEqual(failures,[])
        for title in LaunchRecoveryChoice.allCases.map(\.title)+[VoiceCoachControls.connectTitle,VoiceCoachControls.cancelTitle,VoiceCoachControls.stopTitle,VoiceCoachControls.disconnectTitle] {XCTAssertNil(offending(title),title)}
    }
    /// Display text is never compared as state (D-12). Allowed: the acceptance automation, which checks rendered output on
    /// purpose, and protocol words (a UCI option name, an HTTP scheme).
    func testNoDisplayTextIsComparedAsState()throws {
        let patterns=[#"[=!]=\s*"[A-Z][a-z]*[ ,.…][^"]*""#,#""[A-Z][a-z]+ [^"\\]*"\s*[=!]="#,#"case\s+"[A-Z][a-z]+ [^"\\]*""#,#"\b(?:status|busyReason|title|message|reason)\s*[=!]=\s*"[A-Z]"#]
        let allowed:[(file:String,fragment:String)]=[("CheckmateNative/App.swift",""),("CheckmateDomain/OpponentPolicy.swift","\"Skill Level\""),("CheckmateMacPlatform/CompanionBroker.swift","\"Bearer ")]
        var failures:[String]=[]
        for line in try sourceLines() {for pattern in patterns {for hit in matches(pattern,line.text) where !allowed.contains(where:{line.file==$0.file && ($0.fragment.isEmpty || hit.contains($0.fragment))}) {failures.append("\(line.file):\(line.line) \(hit)")}}}
        XCTAssertEqual(failures,[],"compare a typed identifier, and map it to text only in the view")
        XCTAssertFalse(matches(patterns[0],#"if label=="Return to game"{"#).isEmpty,"the scan catches a comparison")
    }
    /// Counted text is a whole format string per form (D-13): no English suffix or verb glued on by a count test.
    func testCountedTextUsesWholeForms()throws {
        let pattern=#"==\s*1\s*\?\s*"[A-Za-z]*"\s*:\s*"[A-Za-z]*""#
        let failures=try sourceLines().filter{!matches(pattern,$0.text).isEmpty}.map{"\($0.file):\($0.line)"}
        XCTAssertEqual(failures,[],"use Plural.count with a whole sentence for each form")
        XCTAssertFalse(matches(pattern,#"\(n) move\(n==1 ? "":"s")"#).isEmpty,"the scan catches a glued suffix")
    }
    /// Shown text uses US spelling (D-16). A word inside a literal counts; identifiers, comments and one-word wire values
    /// ("cancelled" in the MCP job states) do not. The calibration file is exempt: its text is part of the source hash
    /// its recorded results were made against, so it changes only with a new calibration run.
    func testShownTextUsesUSSpelling()throws {
        let word=try NSRegularExpression(pattern:#"(?i)(?<=[ "])(?:colou?rs?|coloured|favou?rs?|centred?|practise[sd]?|labelled|cancelled|cancelling|behaviour|analyse[sd]?|defence|grey|licence|organis\w*|recognis\w*)(?=[ .,;:!?"])"#)
        let british=try NSRegularExpression(pattern:#"(?i)colour|favour|centre|practis|labell|cancell|behaviour|analyse|defence|grey|licence|organis|recognis"#)
        func hits(_ text:String)->[String] {
            let ns=text as NSString
            return word.matches(in:text,range:NSRange(location:0,length:ns.length)).compactMap{m in
                let found=ns.substring(with:m.range)
                guard british.firstMatch(in:found,range:NSRange(location:0,length:(found as NSString).length)) != nil else{return nil}
                let before=ns.substring(to:m.range.location),end=m.range.location+m.range.length
                let quotes=before.replacingOccurrences(of:#"\""#,with:"").filter{$0=="\""}.count
                guard quotes % 2 == 1 else{return nil}
                if before.hasSuffix("\"") && end<ns.length && ns.substring(with:NSRange(location:end,length:1))=="\"" {return nil}
                return found
            }
        }
        var failures:[String]=[]
        for line in try sourceLines() where !line.text.trimmingCharacters(in:.whitespaces).hasPrefix("//") && line.file != "CheckmateDomain/PositionGameCalibration.swift" {
            for found in hits(line.text) {failures.append("\(line.file):\(line.line) \(found)")}
        }
        XCTAssertEqual(failures,[],"write US English in shown text")
        XCTAssertEqual(hits(#"Text("Board colours")"#),["colours"]);XCTAssertEqual(hits(#"var centre:[Item]=[]"#),[]);XCTAssertEqual(hits(#"job.status="cancelled""#),[])
    }
    func testSettingsCategoryRestoresItsIdentifierAndOlderTitles() {
        for category in SettingsCategory.allCases {XCTAssertEqual(SettingsCategory(stored:category.rawValue),category)}
        let older:[String:SettingsCategory]=["Chessboard":.board,"Sound":.sound,"Lessons":.lessons,"Practice":.practice,"Voice Coach":.voice,"Connections":.connections,"Usage":.usage,"About":.about]
        for (title,category) in older {XCTAssertEqual(SettingsCategory(stored:title),category,"a save from before identifiers stored \(title)")}
        XCTAssertEqual(SettingsCategory(stored:"Something else"),.board)
    }
    func testDrawersAndProgressUseTheirOwnMetrics() {
        XCTAssertEqual(Metrics.drawerAnimation,0.3,accuracy:0.0001)
        XCTAssertGreaterThanOrEqual(Metrics.playbackLineHeight,4)
        XCTAssertLessThan(Metrics.tightGap,Metrics.smallGap);XCTAssertLessThan(Metrics.smallGap,Metrics.padding);XCTAssertLessThan(Metrics.padding,Metrics.sectionGap)
    }
}
