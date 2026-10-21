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
        XCTAssertEqual(hits(#"let x=AttributedString(localized:"Leaves opening theory at \(move)",bundle:.checkmate)"#),[])
        XCTAssertEqual(hits(#"Text("Hello there");Button("Open Game"){}"#),[])
        XCTAssertEqual(hits(#"let event=d.header("Event")"#),[])
        XCTAssertEqual(hits(#"precondition(ok,"The state is broken")"#),[])
        XCTAssertEqual(hits(#"NativeLog.network.info("Peer went away")"#),[])
        XCTAssertEqual(hits(#"if title=="Open Game"{}"#),[])
        XCTAssertEqual(hits(#"let wire="Not shown here" // not localized: wire value"#),[])
        XCTAssertEqual(hits("case gentle=\"Gentle Play\""),[])
        // A multi-line or raw literal reaches the screen like any other.
        XCTAssertEqual(hits("let s=\"\"\"\nSome text here\n\"\"\""),["Some text here"])
        XCTAssertEqual(hits(##"let r=#"Some raw text"#;let p=#"^\[[A-Z]+\s+""#"##),["Some raw text"])
        // So does a format string, its specifiers read as interpolations.
        XCTAssertEqual(hits(#"LabeledContent("Duration",value:String(format:"%.1f seconds",d));let h=String(format:"%02x",b)"#),["\u{1} seconds"])
        XCTAssertEqual(hits(#"let m=["Some key":1]"#),[])
        XCTAssertEqual(hits(#"let id="board-square""#),[])
        XCTAssertEqual(lint.analyse(#"precondition(ok,String(localized:"The state is broken",bundle:.checkmate))"#).misplaced,[1])
        // An interpolation hides the capital the first pattern looks for, and a piece of a sentence has too few words.
        XCTAssertEqual(hits(#"text="\(who) castled kingside""#),["\u{1} castled kingside"])
        XCTAssertEqual(hits(#"sheet.title="\(kind.title) review""#),["\u{1} review"])
        XCTAssertEqual(hits(#"text+=", check";text+=" en passant";s=flag ? "you get ":"x""#),[", check"," en passant","you get "])
        XCTAssertEqual(hits(#"Text(done ? String(localized:"Checking more deeply",bundle:.checkmate):"\(a) / \(b) moves")"#),["\u{1} / \u{1} moves"])
        XCTAssertEqual(hits(#"parts.append(x ? "capture destination":"possible destination, not playable now")"#),["capture destination","possible destination, not playable now"])
        XCTAssertEqual(hits(#"let id="gen-\(entry)-t\(tier)";let p="\(dir)/file.json";let s="\(a) \(b)";let q="\(n)s";let k="selected""#),[])
        XCTAssertEqual(hits(#"status=text+"\nRefreshed \(date)""#),["\nRefreshed \u{1}"])
        XCTAssertEqual(hits(#"lines.append("Account-wide token activity unavailable.");let h="Content-Type""#),["Account-wide token activity unavailable."])
        XCTAssertEqual(hits(#"let id="lesson:\(n)";let js="g.load(\(fen))";let f="(()=>{const g=new exports.Chess();g.loadPgn(\(p))})()""#),[])
        // Text inside an interpolation reaches the screen too, and a localized sentence does not translate it.
        XCTAssertEqual(hits(#"let a=String(localized:"\(side=="b" ? "Black":"White") to move",bundle:.checkmate)"#),["Black","White"])
        XCTAssertEqual(hits(#"let a=String(localized:"\(x ? String(localized:"Black",bundle:.checkmate):name) to move",bundle:.checkmate)"#),[])
        // A catalog key that is a piece of a sentence cannot be reordered by a translator.
        func fragments(_ code:String)->[String] {lint.analyse(code).fragments.map(\.text)}
        XCTAssertEqual(fragments(#"let a=String(localized:"Hide ",bundle:.checkmate)+b;Text(" · Check");let c=String(localized:", not done yet",bundle:.checkmate)"#),["Hide "," · Check",", not done yet"])
        XCTAssertEqual(fragments(#"let a=String(localized:"Hide \(noun)",bundle:.checkmate);Text("Opponent:");let v=Text(verbatim:" x")"#),[])
        // So is a key that stops at a preposition or an article, its sentence finished by the view beside it.
        XCTAssertEqual(fragments(#"HStack{Text("Leaves opening theory at");Button(move){}};let a=String(localized:"Move it to",bundle:.checkmate);Text("Captured by the");Text("Choose a")"#),["Leaves opening theory at","Move it to","Captured by the","Choose a"])
        XCTAssertEqual(fragments(#"Text("Sort By");Button("Sign In"){};Toggle("Play On",isOn:$on);Text("Allow the coach to play a move you ask for");let a=AttributedString(localized:"Leaves opening theory at \(move)",bundle:.checkmate)"#),[],"a title-case control and a whole sentence ending in a preposition are finished")
        // A color beside a piece name cannot agree with the piece's gender: the color and piece are one phrase, one key.
        func composed(_ code:String)->[String] {lint.analyse(code).composed.map(\.text)}
        XCTAssertEqual(composed(#"let a=String(localized:"Move the \(PieceName.color(c)) \(PieceName.of(p)) to \(s).",bundle:.checkmate);let b=String(localized:"\(PieceName.side(c)) \(name) on \(s)",bundle:.checkmate)"#),["Move the \u{1} \u{1} to \u{1}.","\u{1} \u{1} on \u{1}"])
        XCTAssertEqual(composed(#"let a=String(localized:"Select every \(side) piece here.",bundle:.checkmate);let b=String(localized:"Follow each \(side) piece's lines.",bundle:.checkmate);Text("\(side)’s king is in check")"#),["Select every \u{1} piece here.","Follow each \u{1} piece's lines.","\u{1}’s king is in check"])
        XCTAssertEqual(composed(#"let a=String(localized:"\(PieceName.side(c)) moved \(PieceName.phrase(p,.object)).",bundle:.checkmate);let b=String(localized:"It is \(side(turn))'s move.",bundle:.checkmate);let c=String(localized:"Move \(PieceName.the(c,p)) to \(s).",bundle:.checkmate)"#),[])
        // Nor can an article or a possessive agree with a piece name it does not know: the article is part of the phrase.
        XCTAssertEqual(composed(#"let a=String(localized:"\(PieceName.side(c)) moved the \(PieceName.of(p)).",bundle:.checkmate);let b=String(localized:"A \(name) cannot move.",bundle:.checkmate);Text("Try moving your \(piece) on \(s).");let d=String(localized:"You have no \(name).",bundle:.checkmate)"#),["\u{1} moved the \u{1}.","A \u{1} cannot move.","Try moving your \u{1} on \u{1}.","You have no \u{1}."])
        XCTAssertEqual(composed(#"let a=String(localized:"\(count) \(pieces) can move to \(to).",bundle:.checkmate);let b=String(localized:"Duplicate header \(name).",bundle:.checkmate)"#),[])
        // Plain code joins a color and a piece name as surely as a key does, once the joined text is shown.
        XCTAssertEqual(composed(#"parts += [PieceName.side(String(p.prefix(1))),PieceName.of(String(p.suffix(1)))]"#),["PieceName.side(String(p.prefix(1))),PieceName.of(String(p.suffix(1)))"])
        XCTAssertEqual(composed(#"let t=PieceName.side(c)+" "+PieceName.of(k);let u=side+" "+piece"#),[#"PieceName.side(c)+" "+PieceName.of(k)"#,#"side+" "+piece"#])
        XCTAssertEqual(composed(#"label.stringValue="\(side) \(piece)""#),["\u{1} \u{1}"])
        XCTAssertEqual(composed(#"NativeLog.ui.info("\(side) \(piece)");let a=[PieceName.side(c),String(n)];let b=PieceName.named(c,p);let c=side+piece.count"#),[])
        XCTAssertEqual(composed("let u=side+\" \"+piece // not localized: a planted exception\n// let v=PieceName.side(c)+PieceName.of(p)"),[])
        // A piece is known by its value's name, not only `piece` or `name`.
        XCTAssertEqual(composed(#"Text("You took the \(captured).");let a=String(localized:"Move a \(kind) here.",bundle:.checkmate);let b=String(localized:"Your \(move.pieceName) is pinned.",bundle:.checkmate)"#),["You took the \u{1}.","Move a \u{1} here.","Your \u{1} is pinned."])
        // A word between the determiner and the piece does not make them agree.
        XCTAssertEqual(composed(#"let a=String(localized:"Move the white \(piece).",bundle:.checkmate);Text("Guard your own \(name).")"#),["Move the white \u{1}.","Guard your own \u{1}."])
        // Every determiner, not only an article or a possessive.
        XCTAssertEqual(composed(#"Text("Select every \(piece).");Text("Move each \(piece).");Text("Is this \(piece) safe?");Text("Take that \(piece).");Text("Can any \(piece) move?");Text("Find another \(piece).");Text("Guard our \(piece).")"#),["Select every \u{1}.","Move each \u{1}.","Is this \u{1} safe?","Take that \u{1}.","Can any \u{1} move?","Find another \u{1}.","Guard our \u{1}."])
        // A color call qualified by its type is still a color.
        XCTAssertEqual(composed(#"let a=String(localized:"\(TypedMove.side(c)) \(piece) moved.",bundle:.checkmate);let t=TypedMove.side(c)+" "+PieceName.of(p)"#),["\u{1} \u{1} moved.",#"TypedMove.side(c)+" "+PieceName.of(p)"#])
        // Plain code joins the piece first, or two bare values in a list, as surely; but a call's two arguments are no join.
        XCTAssertEqual(composed(#"let t=PieceName.of(p)+" "+side;let u=piece+" "+PieceName.side(c);let v=[side,piece];let w=[PieceName.of(p),side]"#),[#"PieceName.of(p)+" "+side"#,#"piece+" "+PieceName.side(c)"#,"side,piece","PieceName.of(p),side"])
        XCTAssertEqual(composed(#"let a=PieceName.named(side,piece);let b=[side,piece,square];let c=side+" to move";let d=m.color+m.piece"#),[])
        // A join written across lines.
        XCTAssertEqual(composed("let t=PieceName.side(c)+\n    \" \"+PieceName.of(p)"),["PieceName.side(c)+\n    \" \"+PieceName.of(p)"])
        XCTAssertEqual(lint.analyse("let a=1\nlet t=side+\n    \" \"+piece").composed.map(\.line),[2])
        // Multi-line and raw literals, and format strings, written or localized, with their arguments in any order.
        XCTAssertEqual(composed("let s=\"\"\"\nMove the \\(side) \\(piece).\n\"\"\""),["Move the \u{1} \u{1}."])
        XCTAssertEqual(composed(##"let r=#"Move the \#(side) \#(piece)."#;let q=#"\(side) \(piece)"#"##),["Move the \u{1} \u{1}."])
        XCTAssertEqual(composed(#"let a=String(format:"Move the %@ %@.",side,piece);let b=String(format:String(localized:"Move the %2$@ %1$@.",bundle:.checkmate),piece,side);let c=String(format:"%@ %@",side,count)"#),["Move the \u{1} \u{1}.","Move the \u{1} \u{1}."])
    }

    func testShownTextGoesThroughTheCatalog()throws {
        let files=try XCTUnwrap(FileManager.default.enumerator(at:Self.sources,includingPropertiesForKeys:nil)).compactMap{$0 as? URL}.filter{$0.pathExtension=="swift"}
        XCTAssertGreaterThan(files.count,50,"the scan found the sources")
        let lint=LocalizationLint(),calibrated=try calibrated();var scanned=0,bypassing:[String]=[],misplaced:[String]=[],fragments:[String]=[],composed:[String]=[]
        for url in files {
            let file=String(url.path.dropFirst(Self.sources.path.count+1))
            guard !Self.skippedTargets.contains(String(file.prefix{$0 != "/"})),!Self.skippedFiles.contains(file),!calibrated.contains(file) else{continue}
            let found=lint.analyse(try String(contentsOf:url,encoding:.utf8));scanned+=found.literals
            bypassing+=found.hits.map{"\(file):\($0.line) \($0.text)"};misplaced+=found.misplaced.map{"\(file):\($0)"};fragments+=found.fragments.map{"\(file):\($0.line) \($0.text)"};composed+=found.composed.map{"\(file):\($0.line) \($0.text)"}
        }
        XCTAssertGreaterThan(scanned,5000,"the lint saw the app's literals")
        XCTAssertEqual(bypassing,[],"shown text: use String(localized:…,bundle:.checkmate), or mark developer text with // not localized: <reason>")
        XCTAssertEqual(misplaced,[],"developer text (a precondition, log or tag) is not shown: keep it out of the String Catalog")
        XCTAssertEqual(fragments,[],"a piece of a sentence cannot be reordered: localize the whole sentence, with interpolations for what varies")
        XCTAssertEqual(composed,[],"a color or article beside a piece name cannot agree with it: name the piece with PieceName.phrase, .the, .bracketed, .named or .listed")
    }

    /// Every key the code uses is a whole text, never a piece joined to others (stale keys are no longer in the code).
    func testTheCatalogHoldsNoFragments()throws {
        struct Catalog:Decodable {struct Entry:Decodable {let extractionState:String?};let strings:[String:Entry]}
        let catalog=try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:Self.sources.appendingPathComponent("CheckmateCore/Localizable.xcstrings")))
        XCTAssertGreaterThan(catalog.strings.count,1000,"the catalog was read")
        XCTAssertEqual(catalog.strings.filter{$0.value.extractionState != "stale" && LocalizationLint.isFragment($0.key)}.keys.sorted(),[],"a key starting or ending with a space, starting with a joining mark, or stopping at a preposition or article, is a piece of a sentence")
    }

    func testTheCatalogShipsEnglish() {
        XCTAssertTrue(Bundle.checkmate.localizations.contains("en"),"the resource bundle carries the compiled String Catalog")
        XCTAssertEqual(String(localized:"\(1) moves",bundle:.checkmate),"1 move")
        // A count among several varies only its own words, through a catalog substitution.
        XCTAssertEqual(String(localized:"\(0) of \(1) moves could not be analyzed.",bundle:.checkmate),"0 of 1 move could not be analyzed.")
        XCTAssertEqual(String(localized:"\(1) operations · \(2) sessions",bundle:.checkmate),"1 operation · 2 sessions")
        XCTAssertEqual(String(localized:"Move \("the white rook") from \("a1") to \("a8") in at most \(1) moves.",bundle:.checkmate),"Move the white rook from a1 to a8 in at most 1 move.")
    }

    /// A piece named by color and kind is one key for each color and kind, and the English reads as it did when the
    /// color and the piece were separate words.
    func testPieceNamesByColorKeepTheirEnglish()throws {
        XCTAssertEqual(PieceName.the("w","n"),"the white knight");XCTAssertEqual(PieceName.the("b","q"),"the black queen");XCTAssertEqual(PieceName.the("W",nil),"the white piece")
        XCTAssertEqual(PieceName.named("w","r"),"White rook");XCTAssertEqual(PieceName.named("b","k"),"Black king")
        XCTAssertEqual(PieceName.listed("w","p"),"White, pawn");XCTAssertEqual(PieceName.listed("b","B"),"Black, bishop")
        XCTAssertEqual(RelationshipInspection.label(color:"w",piece:"n",square:"f3"),"White knight on f3");XCTAssertEqual(RelationshipInspection.label(color:"b",piece:"q",square:"d8"),"Black queen on d8")
        let mate=try ReviewExplanation.make(document:PGNImporter.parse(Data("1. f3 e5 2. g4 Qh4# 0-1".utf8))[0],node:0)
        XCTAssertEqual(mate.takeaways.first,"The final White king has no legal answer to check. Replay the last moves to see how its escape squares disappeared.")
        // Generated training text, against English templates written out here.
        let names=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"],kinds=["p","n","b","r","q","k"]
        func the(_ piece:String)->String {"the \(piece.first=="w" ? "white":"black") \(names[String(piece.last!)]!)"}
        var reached=0,occupied=0,empty=0
        for seed in 0..<60 {
            for color:Character in ["w","b"] {
                if let s=TrainingGenerator.reachTarget(seed:UInt64(seed),tier:1+seed%3,color:color,piece:kinds[seed%6]),let d=s.drill,let budget=s.budget {
                    XCTAssertEqual(s.prompt,s.shortest==true ? "Move \(the(d.piece)) from \(d.start) to \(d.target) in the fewest moves: \(budget).":"Move \(the(d.piece)) from \(d.start) to \(d.target) in at most \(budget) move\(budget==1 ? "":"s").");reached+=1
                }
                let side=color=="w" ? "White":"Black"
                for defenders in [false,true] {
                    guard let s=defenders ? TrainingGenerator.findDefenders(seed:UInt64(seed),tier:1+seed%3,color:color):TrainingGenerator.findAttackers(seed:UInt64(seed),tier:1+seed%3,color:color),let target=s.target,let board=s.diagram else{continue}
                    let on=board[target].map{" (\(the($0)))"} ?? "";if !on.isEmpty{occupied+=1}
                    XCTAssertEqual(s.prompt,defenders ? "Select every \(side) piece that protects the piece on \(target)\(on). Choose None if nothing protects it.":"Select every \(side) piece that attacks \(target)\(on). Choose None if no \(side) piece attacks it.")
                    XCTAssertEqual(s.hints,[defenders ? "Which other \(side) pieces attack \(target)? Follow their lines and jumps; a line stops at the first piece in the way. A pinned piece or a king still counts as protecting here.":"Follow each \(side) piece's lines and jumps. A line stops at the first piece in the way; a pinned piece still attacks."])
                    if s.expected?.squares?.isEmpty==true {XCTAssertEqual(s.explanation,"No \(side) piece \(defenders ? "protects":"attacks") \(target).");empty+=1}
                }
            }
        }
        XCTAssertGreaterThan(reached,20);XCTAssertGreaterThan(occupied,20);XCTAssertGreaterThan(empty,0,"the seeds reach every form pinned here")
    }
}

/// A whole-file scan of Swift string literals that tracks the call each literal is an argument of, so a call spanning
/// lines keeps its callee. Comments are skipped; multi-line and raw strings are read like any other.
private struct LocalizationLint {
    final class Frame {
        let callee:String,start:Int;var label:String?,argumentStart:Int,end:Int?
        init(callee:String,start:Int,argumentStart:Int){self.callee=callee;self.start=start;self.argumentStart=argumentStart}
    }
    /// A frame as it stood at one literal: its label then, and its end once the scan closes it.
    struct Snapshot {let frame:Frame,label:String?;var callee:String {frame.callee}}
    /// `interpolations` holds the source of each "\(…)", in order: one for each \u{1} in `text`.
    struct Literal {let start:Int,end:Int,text:String,stack:[Snapshot],prefix:String,interpolations:[String]}
    enum Kind {case localized,developer,swiftUI}

    private let prose=try! NSRegularExpression(pattern:#"^[\W\x{01}]*(?:[A-Z](?:[a-z’']+(?:$|[ ,.…?!:;\x{01}’'])|[a-z’']*-[a-z]+ [a-z]| [a-z])|[a-z][a-z’']* [a-z’']+ [a-z])"#)
    /// Prose the pattern above misses: a lowercase word in a literal that interpolates ("\(n) moves", "\(name) review"),
    /// or in a piece of a sentence that starts or ends with a space (", check", " en passant", "you get "), and a
    /// lowercase phrase of two words or more ("capture destination", "possible destination, not playable now").
    private let word=try! NSRegularExpression(pattern:#"(?:^|\s)[a-z][a-z’']+(?=$|[\s,.…?!:;\x{01}])"#),edge=try! NSRegularExpression(pattern:#"^\W*\s|\s$"#)
    private let phrase=try! NSRegularExpression(pattern:#"^[a-z][a-z’']*(?:[,;]? [a-z][a-z’']*)+[.!?…]?$"#)
    /// An identifier ("lesson:\(id)") has no space, and code ("g.load(\(fen))", "()=>{…}") has its own punctuation.
    func isProse(_ text:String)->Bool {
        if first(prose,text) != nil || first(phrase,text) != nil {return true}
        return first(word,text) != nil && (text.contains("\u{1}") || first(edge,text) != nil) && text.contains(" ") && !text.contains{"{}=".contains($0)}
    }
    /// A key starting or ending with a space, starting with a joining mark, or stopping at a lowercase preposition or
    /// article ("Leaves opening theory at" beside a move button): a piece of a sentence, which a translator cannot reorder.
    /// A title-case control ("Sort By") and a sentence ending in its own preposition ("a move you ask for") are whole.
    static func isFragment(_ key:String)->Bool {guard let first=key.first,let last=key.last else{return false};return first.isWhitespace || ",;.·".contains(first) || last.isWhitespace || key.range(of:#"(?:^|\s)(?:at|on|to|of|the|a|an)$"#,options:.regularExpression) != nil}
    /// A color or side beside a piece name ("the \(color) \(piece)", "\(side) piece", "\(side)'s knight"), or an article,
    /// possessive or other determiner before one, perhaps with a word or two between ("the \(piece)", "a \(name)",
    /// "your own \(piece)", "every \(kind)"): neither the color nor the determiner can agree with the piece's gender. An
    /// interpolation counts as a color or a piece by its source: a call that names one, qualified or not
    /// (`TypedMove.side(c)`, `PieceName.of(p)`), or a value whose name says so (`side`, `move.color`, `piece`, `kind`,
    /// `captured`, `pieceName`, `name`).
    private static let colorValue=#"(?:[a-z_]\w*\.)*(?:side|theirs|ours|color|colour)"#,pieceValue=#"(?:[a-z_]\w*\.)*(?:(?:[a-z]\w*)?(?:[Pp]iece(?:[Nn]ame)?|[Kk]ind|[Cc]aptured?)s?|names?)"#
    private let colorSource=try! NSRegularExpression(pattern:"^"+Self.colorValue+#"$|\b(?:side|color|colorName)\("#)
    private let pieceSource=try! NSRegularExpression(pattern:"^"+Self.pieceValue+#"$|\bPieceName\.(?:of|plural)\("#)
    private let composition=try! NSRegularExpression(pattern:#"\x{02}(?:['’]s)?\s+(?:\x{03}|(?:pawn|knight|bishop|rook|queen|king|piece)s?\b)|(?:^|[^\w])(?:[Tt]he|[Aa]n?|[Yy]our|[Nn]o|[Mm]y|[Oo]ur|[Tt]heir|[Hh]is|[Hh]er|[Ii]ts|[Ee]very|[Ee]ach|[Tt]his|[Tt]hat|[Tt]hese|[Tt]hose|[Aa]ny|[Aa]nother)(?:\s+[a-z’']+){0,2}\s+\x{03}"#)
    /// Plain code that joins a color and a piece name, either first, with `+` or in a list (`side+" "+piece`,
    /// `PieceName.of(p)+" "+side`, `[PieceName.side(c),PieceName.of(p)]`, `[side,piece]`), on one line or across lines.
    /// Calls nest up to three deep; two bare values count only as a whole array literal, since a call takes its
    /// arguments the same way. A `+` join counts only with text between its parts: with none (`m.color+m.piece`) it
    /// spells a board code, not a phrase.
    private let joined:NSRegularExpression={
        let call=#"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"#,glue=#"\s*\+\s*"[^"\\]+"\s*\+\s*"#,comma=#"\s*,\s*"#
        let colorCall=#"\b(?:[A-Za-z_]\w*\.)*(?:side|color|colorName)"#+call,pieceCall=#"\bPieceName\.(?:of|plural)"#+call
        let color="(?:"+colorCall+#"|(?<![.\w])"#+Self.colorValue+#"(?![\w(.]))"#,piece="(?:"+pieceCall+#"|(?<![.\w])"#+Self.pieceValue+#"(?![\w(.]))"#
        let listed=#"(?<=\[\s{0,4})(?:"#+color+comma+piece+"|"+piece+comma+color+#")(?=\s*\])"#
        return try! NSRegularExpression(pattern:color+glue+piece+"|"+piece+glue+color+"|"+colorCall+comma+pieceCall+"|"+pieceCall+comma+colorCall+"|"+listed)
    }()
    func isComposed(_ literal:Literal)->Bool {
        var sources=literal.interpolations.makeIterator()
        let shape=String(literal.text.map{c->Character in guard c=="\u{1}",let source=sources.next()?.trimmingCharacters(in:.whitespaces) else{return c};return first(colorSource,source) != nil ? "\u{2}":first(pieceSource,source) != nil ? "\u{3}":c})
        return first(composition,shape) != nil
    }
    private let swiftUI:Set<String>=["Text","Button","Toggle","Label","Picker","Section","Menu","LabeledContent","GroupBox","TextField","SecureField","Link","DisclosureGroup","ProgressView","Stepper","ControlGroup","Tab",".help",".accessibilityLabel",".accessibilityHint",".accessibilityValue",".navigationTitle",".alert",".confirmationDialog",".value"]
    private let developerCallees:Set<String>=["print","NSLog","fatalError","precondition","preconditionFailure","assert","assertionFailure","Logger","appendingPathComponent","appendingPathExtension","NSUserInterfaceItemIdentifier","Notification.Name","header","known","tag","PGNHeader","ProtocolFailure","setAccessibilityIdentifier","accessibilityIdentifier","identifier","hasPrefix","hasSuffix","contains","starts","components","firstIndex","lastIndex","split","range"]
    private let developerLabels:Set<String>=["fileURLWithPath","forKey","path","forHTTPHeaderField","debugDescription","instructions","comment","identifier","withIdentifier","systemName","systemImage","systemSymbolName","named","forResource","withExtension","ofType"]
    private let marker=try! NSRegularExpression(pattern:#"//.*\bnot localized\b"#)
    private let member=try! NSRegularExpression(pattern:#"^    (?:@\w+ )*(?:private |static |public |override |nonisolated )*(?:func|var|let|init)\b"#)
    private let scenario=try! NSRegularExpression(pattern:#"^    (?:@\w+ )*(?:private |static |public )*func (run\w*)\b"#)

    private func first(_ regex:NSRegularExpression,_ text:String)->NSTextCheckingResult? {regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text))}
    private func has(_ pattern:String,_ text:String)->Bool {first(try! NSRegularExpression(pattern:pattern),text) != nil}
    private static func isIdentifier(_ c:Character)->Bool {c.isLetter || c.isNumber || c=="_" || c=="."}

    func scan(_ s:[Character])->[Literal] {scan(s,from:0,to:s.count,outer:[])}
    /// Scans `s[from..<to]`. A literal inside an interpolation is scanned too, under a barrier frame: "\(white ? "White":"Black")"
    /// puts English into a localized sentence unless the inner text is localized itself.
    func scan(_ s:[Character],from:Int,to n:Int,outer:[Snapshot])->[Literal] {
        var i=from,stack:[Frame]=[],out:[Literal]=[]
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
            // A string literal: "…", a multi-line """…""", or a raw #"…"# (any number of #s, its escapes and
            // interpolations written \#…), each scanned the same way.
            if c=="\"" || c=="#" {
                var hashes=0;while i+hashes<n,s[i+hashes]=="#"{hashes+=1}
                guard i+hashes<n,s[i+hashes]=="\"" else{i+=max(1,hashes);continue}
                let start=i,current=outer+stack.map{Snapshot(frame:$0,label:$0.label)},multiline=starts("\"\"\"",i+hashes),pound=String(repeating:"#",count:hashes)
                let close=(multiline ? "\"\"\"":"\"")+pound,escape="\\"+pound;i+=hashes+(multiline ? 3:1)
                // A multi-line literal's text starts on the line after its opening delimiter.
                if multiline{while i<n,s[i] != "\n"{i+=1};i+=1}
                var parts="",nested:[Literal]=[],interpolations:[String]=[]
                while i<n,!starts(close,i),multiline || s[i] != "\n" {
                    if starts(escape+"(",i){
                        var depth=1;i+=escape.count+1;let inner=i
                        while i<n,depth>0 {
                            if s[i]=="("{depth+=1}else if s[i]==")"{depth-=1}
                            else if s[i]=="\""{i+=1;while i<n,s[i] != "\""{i+=s[i]=="\\" ? 2:1}}
                            i+=1
                        }
                        let barrier=Snapshot(frame:Frame(callee:"\\(",start:inner-escape.count-1,argumentStart:inner),label:nil)
                        nested+=scan(s,from:inner,to:max(inner,i-1),outer:current+[barrier]);interpolations.append(String(s[inner..<max(inner,i-1)]));parts.append("\u{1}");continue
                    }
                    // A line break or tab reads as the space it is, so "\nRefreshed …" still starts a sentence.
                    if starts(escape,i){let k=i+escape.count;parts+=k<n && "nt".contains(s[k]) ? "\n":String(s[i..<min(k+1,n)]);i=k+1;continue}
                    parts.append(s[i]);i+=1
                }
                // Nor does the line break before a multi-line literal's closing delimiter belong to its text.
                if multiline,let last=parts.lastIndex(of:"\n"),parts[last...].dropFirst().allSatisfy({$0==" " || $0=="\t"}){parts=String(parts[..<last])}
                let prefix=stack.last.map{String(s[$0.argumentStart..<start])} ?? ""
                out.append(Literal(start:start,end:min(i+close.count,n),text:parts,stack:current,prefix:prefix,interpolations:interpolations));out+=nested;i+=close.count;continue
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
        if ["String","AttributedString"].contains(callee) && ["localized","defaultValue"].contains(frame.label ?? "") || ["LocalizedStringResource","LocalizedStringKey","String.LocalizationValue"].contains(callee){return .localized}
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

    /// A specifier in a format string ("%@", "%2$@", "%.1f", "%%"), or an interpolation already in its text.
    private let specifier=try! NSRegularExpression(pattern:#"\x{01}|%%|%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSaAp]"#)
    private let labelled=try! NSRegularExpression(pattern:#"^\w+\s*:(?!:)"#)
    /// The format of `String(format:…)`, written in place or as a localized key, is read like an interpolating literal:
    /// each specifier becomes an interpolation whose source is the argument it takes ("%2$@" the second).
    func formatted(_ s:[Character],_ literal:Literal)->Literal {
        func isFormat(_ snapshot:Snapshot)->Bool {snapshot.callee=="String" && snapshot.label=="format"}
        let stack=literal.stack,count=stack.count,call:Snapshot,from:Int
        if let last=stack.last,isFormat(last){call=last;from=literal.end}
        else if count>1,stack[count-1].callee=="String",stack[count-1].label=="localized",isFormat(stack[count-2]),let end=stack[count-1].frame.end{call=stack[count-2];from=end}
        else{return literal}
        guard let end=call.frame.end,from<end else{return literal}
        // The call's arguments after the format, split at its own commas; a labelled one (locale:) is not a value.
        var arguments:[String]=[],current="",depth=0,quoted=false,k=from
        while k<end-1 {
            let c=s[k]
            if quoted{if c=="\\",k+1<end-1{current.append(c);current.append(s[k+1]);k+=2;continue};if c=="\""{quoted=false}}
            else if c=="\""{quoted=true}else if "([{".contains(c){depth+=1}else if ")]}".contains(c){depth-=1}
            else if c==",",depth==0{arguments.append(current);current="";k+=1;continue}
            current.append(c);k+=1
        }
        arguments.append(current)
        let values=arguments.dropFirst().map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{first(labelled,$0)==nil}
        var text="",sources:[String]=[],existing=literal.interpolations.makeIterator(),next=0,cursor=literal.text.startIndex
        for match in specifier.matches(in:literal.text,range:NSRange(literal.text.startIndex...,in:literal.text)) {
            guard let range=Range(match.range,in:literal.text) else{continue};text+=literal.text[cursor..<range.lowerBound];cursor=range.upperBound
            switch literal.text[range] {
            case "\u{1}":text+="\u{1}";sources.append(existing.next() ?? "")
            case "%%":text+="%"
            default:
                let index:Int;if let position=Range(match.range(at:1),in:literal.text).flatMap({Int(literal.text[$0])}){index=position-1}else{index=next;next+=1}
                text+="\u{1}";sources.append(values.indices.contains(index) ? values[index]:"")
            }
        }
        text+=literal.text[cursor...]
        return Literal(start:literal.start,end:literal.end,text:text,stack:literal.stack,prefix:literal.prefix,interpolations:sources)
    }

    /// Prose literals that bypass the catalog, the lines where developer text was put into it, catalog keys that are
    /// pieces of a sentence, and catalog keys that put a color beside a piece name.
    func analyse(_ text:String)->(literals:Int,hits:[(line:Int,text:String)],misplaced:[Int],fragments:[(line:Int,text:String)],composed:[(line:Int,text:String)]) {
        let s=Array(text),lines=text.components(separatedBy:"\n");var lineStarts=[0]
        for line in lines {lineStarts.append(lineStarts.last!+line.count+1)}
        func lineOf(_ offset:Int)->Int {var low=0,high=lineStarts.count;while low<high {let mid=(low+high)/2;if lineStarts[mid]<=offset{low=mid+1}else{high=mid}};return low}
        let skipped=excludedLines(lines),literals=scan(s).map{formatted(s,$0)};var hits:[(line:Int,text:String)]=[],misplaced:[Int]=[],fragments:[(line:Int,text:String)]=[],composed:[(line:Int,text:String)]=[]
        for literal in literals {
            let line=lineOf(literal.start)
            guard !skipped.contains(line) else{continue}
            let isKey=literal.stack.last.map{["String","AttributedString"].contains($0.callee) && $0.label=="localized" || kind($0) == .swiftUI && literal.prefix.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty} ?? false
            if isKey,Self.isFragment(literal.text){fragments.append((line,literal.text))}
            // A key is translated whole; any other literal that is not developer text may still be shown as it is.
            if isKey || kind(literal.stack.last) != .developer,isComposed(literal){composed.append((line,literal.text))}
            guard isProse(literal.text) else{continue}
            if !isAccountedFor(s,literal){hits.append((line,literal.text));continue}
            guard let frame=literal.stack.last,frame.callee=="String",kind(frame) == .localized,literal.stack.count>1,kind(literal.stack[literal.stack.count-2]) == .developer,let end=frame.frame.end,s[frame.frame.start..<end].filter({$0=="\""}).count==2 else{continue}
            misplaced.append(line)
        }
        // Joins are matched over the whole file with its comments left out, so one written across lines is found too.
        let code=lines.map{line in line.range(of:"//").map{String(line[..<$0.lowerBound])} ?? line}.joined(separator:"\n") as NSString
        for match in joined.matches(in:code as String,range:NSRange(location:0,length:code.length)) {
            let found=code.substring(with:match.range),line=code.substring(to:match.range.location).filter{$0=="\n"}.count+1
            if !(line...line+found.filter{$0=="\n"}.count).contains(where:{skipped.contains($0)}){composed.append((line,found))}
        }
        return (literals.count,hits,misplaced,fragments,composed)
    }
}
