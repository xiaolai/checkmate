import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateApplication
import CheckmateDomain

/// R-8 and R-17 on the review board: the Lichess key model and its Go menu, and the evaluation bar's place.
@MainActor final class ReviewGoTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func key(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags=[])->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}

    func testKeysMapToGoCommands() {
        XCTAssertEqual([123,124,126,125,115,119,49].map{ReviewGo(key:$0,imagined:false)},[.previousMove,.nextMove,.previousVariation,.nextVariation,.firstMove,.lastMove,.playPause])
        XCTAssertNil(ReviewGo(key:49,imagined:true),"Space chooses a square in an imagined line");XCTAssertNil(ReviewGo(key:36,imagined:false),"Return chooses a square")
    }
    func testTheBoardKeysMoveThroughLinesAndOptionExploresSquares()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let document=try PGNImporter.parse(Data("1. e4 e5 (1... c5) 2. Nf3 *".utf8))[0],replies=document.nodes[document.mainline[0]].children
        model.review.open(document,practice:model.session);game.refresh();game.window?.makeFirstResponder(game.board)
        XCTAssertTrue(game.board.reviewNavigation)
        game.board.keyDown(with:key(124));game.board.keyDown(with:key(124));XCTAssertEqual(model.review.nodeID,replies[0])
        game.board.keyDown(with:key(125));XCTAssertEqual(model.review.nodeID,replies[1],"↓ chooses the recorded alternative")
        game.board.keyDown(with:key(126));XCTAssertEqual(model.review.nodeID,replies[0],"↑ goes back to the main move")
        try model.review.selectSquare("g1");try model.review.selectSquare("f3");XCTAssertEqual(model.review.branchPly,1);game.refresh()
        XCTAssertTrue(game.board.reviewNavigation,"the keys keep working in an imagined line")
        game.board.keyDown(with:key(123));XCTAssertNil(model.review.branch,"← leaves the idea at its first move");XCTAssertEqual(model.review.nodeID,replies[0])
        game.board.keyDown(with:key(119));XCTAssertEqual(model.review.nodeID,document.mainline.last,"End goes to the line's end")
        game.board.keyDown(with:key(115));XCTAssertEqual(model.review.nodeID,0,"Home goes to its start")
        let focus=game.board.focus;game.board.keyDown(with:key(126,.option));XCTAssertNotEqual(game.board.focus,focus,"Option with an arrow explores squares");XCTAssertEqual(model.review.nodeID,0)
    }
    func testTheGoMenuOffersTheKeysOnlyWhileTheBoardHasThem()throws {
        let model=try NativeModel(),game=GameWindow(model:model),app=AppDelegate(),before=NSApp.mainMenu
        defer{NSApp.mainMenu=before;game.window?.delegate=nil;model.shutdown()}
        app.model=model;app.installMenus(window:game,model:model)
        let go=try XCTUnwrap(NSApp.mainMenu?.items.first{$0.title=="Go"}?.submenu)
        XCTAssertEqual(go.items.map(\.title),["Previous Move","Next Move","Previous Variation","Next Variation","First Move","Last Move"])
        XCTAssertEqual(go.items.map(\.keyEquivalent),ReviewGo.allCases.compactMap(\.menuKey));XCTAssertTrue(go.items.allSatisfy{$0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).isEmpty})
        let next=go.items[1];XCTAssertFalse(game.validateMenuItem(next),"nothing to move through outside a review")
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0];model.review.open(document,practice:model.session);game.refresh()
        game.window?.makeFirstResponder(game.board);XCTAssertTrue(game.validateMenuItem(next))
        let typing=NSTextField(string:"");game.window?.contentView?.addSubview(typing);game.window?.makeFirstResponder(typing)
        XCTAssertFalse(game.validateMenuItem(next),"a text field keeps its arrow keys");typing.removeFromSuperview()
        game.window?.makeFirstResponder(game.board);game.goReview(next);XCTAssertEqual(model.review.nodeID,document.mainline[0])
    }
    /// In an imagined line the board's own keys (Option with an arrow, Space, Return, Escape) pass every menu and reach
    /// the board, which plays a move with them; the menus take only the Go keys. The Window menu carries the "Zoom All"
    /// alternate AppKit adds to it (no key, Option), which a key press without its characters would match.
    func testTheBoardsOwnKeysReachItPastEveryMenuInAnImaginedLine()throws {
        let model=try NativeModel(),game=GameWindow(model:model),app=AppDelegate(),before=NSApp.mainMenu
        defer{NSApp.mainMenu=before;game.window?.delegate=nil;model.shutdown()}
        app.model=model;app.installMenus(window:game,model:model)
        let windows=try XCTUnwrap(NSApp.windowsMenu),answer=ZoomAll(),zoomAll=NSMenuItem(title:"Zoom All",action:#selector(ZoomAll.zoomAll(_:)),keyEquivalent:"");zoomAll.keyEquivalentModifierMask = .option;zoomAll.isAlternate=true;zoomAll.target=answer;windows.addItem(zoomAll)
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0];model.review.open(document,practice:model.session);try model.review.beginBranch();try model.review.selectSquare("e2");try model.review.selectSquare("e4")
        game.refresh();game.window?.makeFirstResponder(game.board);game.board.focus="e4";let menu=try XCTUnwrap(NSApp.mainMenu),number=game.window!.windowNumber
        func press(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags=[])->Bool {let event=NSEvent.keyboardKey(code,modifiers,windowNumber:number);if menu.performKeyEquivalent(with:event){return true};game.board.keyDown(with:event);return false}
        for (code,modifiers) in [(126,NSEvent.ModifierFlags.option),(126,.option),(126,.option),(49,[]),(125,.option),(125,.option),(36,[])] {XCTAssertFalse(press(UInt16(code),modifiers),"key \(code) \(modifiers.rawValue) went to a menu")}
        XCTAssertEqual(model.review.board["e5"],"bp");XCTAssertEqual(model.review.branch?.moves.count,2,"Option-arrows, Space and Return play 1… e5")
        XCTAssertFalse(press(53));XCTAssertTrue(press(123),"← is the Go menu's Previous Move");XCTAssertEqual(model.review.branchPly,1)
    }
    /// Answers the Window menu's "Zoom All" so it stays enabled, as AppKit's own one is.
    private final class ZoomAll:NSObject {@objc func zoomAll(_ sender:Any?){}}
    /// R-8: the move list shows the record's variations, nested ones too, and kept ideas inline, each under the row of
    /// the move it replaces, rather than inside a disclosure.
    func testVariationsAndIdeasSitInlineUnderTheMoveTheyReplace()throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 (1... c5 2. Nf3 (2. c3) d6) 2. Nf3 Nc6 *".utf8))[0],main=document.mainline,c5=document.nodes[main[0]].children[1]
        let nf3=document.nodes[c5].children[0],c3=document.nodes[c5].children[1],d6=document.nodes[nf3].children[0]
        let review=ReviewController();review.load(document);try review.select(main[0]);try review.selectSquare("d7");try review.selectSquare("d5");try review.select(main[1])
        let idea=try XCTUnwrap(review.authoredBranches.first)
        XCTAssertEqual(ReviewFormat.entries(document,ideas:review.authoredBranches),[.row(.init(number:1,white:main[0],black:main[1])),.line([c5,nf3,d6],depth:1),.line([c3],depth:2),.idea(idea),.row(.init(number:2,white:main[2],black:main[3]))])
        XCTAssertEqual([c5,nf3,d6].enumerated().map{ReviewFormat.variationMoveText(document.nodes[$1],first:$0==0)},["1… c5","2. Nf3","d6"])
        XCTAssertEqual(ReviewFormat.entries(document,ideas:[]).count,4,"no ideas, no idea lines")
        try review.select(d6);try review.selectSquare("b1");try review.selectSquare("c3");try review.select(main[3]);try review.selectSquare("f1");try review.selectSquare("b5");try review.select(0)
        let ideas=review.authoredBranches,inLine=try XCTUnwrap(ideas.first{$0.root==d6}),atEnd=try XCTUnwrap(ideas.first{$0.root==main[3]})
        XCTAssertEqual(ReviewFormat.entries(document,ideas:ideas),[.row(.init(number:1,white:main[0],black:main[1])),.line([c5,nf3,d6],depth:1),.line([c3],depth:2),.idea(inLine),.idea(idea),.row(.init(number:2,white:main[2],black:main[3])),.idea(atEnd)],"ideas from inside a variation and after the last move are inline too")
        let ids=ReviewFormat.entries(document,ideas:ideas).map(\.id);XCTAssertEqual(Set(ids).count,ids.count,"each line of the list has its own identity: \(ids)")
    }
    /// The move list names each line by what it shows, not by where it sits, so a line added above a row (a sideline,
    /// an idea) cannot leave that row drawn twice. The release showed "2. c4 e6" twice after a sideline "1… Nf6".
    func testEachMoveListLineKeepsItsIdentityAsLinesAreAdded()throws {
        let document=try PGNImporter.parse(Data("1. d4 d5 (1... Nf6) 2. c4 e6 *".utf8))[0],main=document.mainline,nf6=document.nodes[main[0]].children[1]
        let plain=ReviewFormat.entries(document,ideas:[])
        XCTAssertEqual(plain,[.row(.init(number:1,white:main[0],black:main[1])),.line([nf6],depth:1),.row(.init(number:2,white:main[2],black:main[3]))],"one row per full move: 2. c4 e6 once")
        var idea=ReviewBranch(root:main[3]);idea.moves=["g1f3"];var early=ReviewBranch(root:main[0]);early.moves=["c7c5"]
        let withIdeas=ReviewFormat.entries(document,ideas:[idea,early])
        XCTAssertEqual(withIdeas.filter{if case .row=$0{return true};return false}.count,2,"ideas add no rows")
        XCTAssertEqual(Set(withIdeas.map(\.id)).count,withIdeas.count)
        for entry in plain {XCTAssertEqual(withIdeas.filter{$0.id==entry.id},[entry],"\(entry) keeps its identity when ideas are added")}
    }
    func testTheEvaluationBarSitsRightOfTheBoardWithWhiteOnItsOwnSide() {
        let board=NSRect(x:20,y:20,width:400,height:400),plain=BoardView.evaluationBar(board:board,share:0.75,blackAtBottom:false)
        XCTAssertGreaterThan(plain.white.minX,board.maxX);XCTAssertLessThanOrEqual(plain.white.maxX,board.maxX+20,"inside the margin")
        XCTAssertEqual(plain.white.minY,board.minY);XCTAssertEqual(plain.white.height,300,accuracy:0.001);XCTAssertEqual(plain.black.height,100,accuracy:0.001)
        let flipped=BoardView.evaluationBar(board:board,share:0.75,blackAtBottom:true)
        XCTAssertEqual(flipped.white.maxY,board.maxY);XCTAssertEqual(flipped.white.height,300,accuracy:0.001)
    }
    /// The bar is drawn, so VoiceOver gets it in plain words too, only while it is shown.
    func testTheEvaluationBarIsReadAloudOnlyWhileShown() throws {
        let board=BoardView(frame:NSRect(x:0,y:0,width:440,height:440))
        func bar()->NSAccessibilityElement? {board.accessibilityChildren()?.compactMap{$0 as? NSAccessibilityElement}.first{$0.accessibilityIdentifier()=="board-evaluation"}}
        board.evaluationLabel="Evaluation: White ahead by 1.2 pawns"
        XCTAssertNil(bar(),"no bar, nothing to read")
        board.evaluation=0.75
        let element=try XCTUnwrap(bar());XCTAssertEqual(element.accessibilityRole(),.staticText);XCTAssertEqual(element.accessibilityLabel(),"Evaluation: White ahead by 1.2 pawns")
        board.evaluationLabel=nil;XCTAssertNil(bar(),"a bar without words is not announced as an empty element")
        board.evaluationLabel="Evaluation: even";board.evaluation=nil;XCTAssertNil(bar())
    }
    func testTheEvaluationIsSaidInPlainWordsFromWhitesSide() {
        XCTAssertEqual(ReviewFormat.evaluationLabel(AnalysisScore(kind:"cp",value:120)),"Evaluation: White ahead by 1.2 pawns")
        XCTAssertEqual(ReviewFormat.evaluationLabel(AnalysisScore(kind:"cp",value:-250)),"Evaluation: Black ahead by 2.5 pawns")
        XCTAssertEqual(ReviewFormat.evaluationLabel(AnalysisScore(kind:"cp",value:4)),"Evaluation: even","what shows as 0.0 is even")
        XCTAssertEqual(ReviewFormat.evaluationLabel(AnalysisScore(kind:"mate",value:3)),"Evaluation: White can force checkmate in 3 moves")
        XCTAssertEqual(ReviewFormat.evaluationLabel(AnalysisScore(kind:"mate",value:-1)),"Evaluation: Black can force checkmate in 1 move")
        XCTAssertEqual(ReviewFormat.evaluationLabel(AnalysisScore(kind:"mate",value:0)),"Evaluation: checkmate")
    }
}
