import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Wave 2 board and play: Flip Board everywhere (B-6), the Game menu's Hint and shortcuts (B-17), coordinates on two
/// edges (B-14), the check glow and last-move tint (B-15) and the New Game choices (B-18).
@MainActor final class BoardPlayTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}

    /// B-6: Flip Board works in every mode, and a flip lasts while the same game, lesson or review is shown.
    func testFlipBoardWorksEverywhereAndLastsForWhatIsShown()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let flip=#selector(GameWindow.flipBoard)
        XCTAssertNil(GameWindow.networkItemEnabled(flip,network:false,game:model.network),"outside a network game the window decides")
        model.practice();model.session.cancelWork();game.refresh();XCTAssertFalse(game.board.blackAtBottom)
        XCTAssertTrue(game.validateMenuItem(NSMenuItem(title:"Flip Board",action:flip,keyEquivalent:"")),"Flip Board works in practice")
        game.flipBoard();XCTAssertTrue(game.board.blackAtBottom);game.flipBoard();XCTAssertFalse(game.board.blackAtBottom,"flipping twice turns it back")
        game.flipBoard();model.session.newGame(side:"w");model.session.cancelWork();game.refresh();XCTAssertFalse(game.board.blackAtBottom,"a new game starts from the learner's side")
        model.lesson(0);model.learning.pause();game.refresh();XCTAssertFalse(game.board.blackAtBottom)
        game.flipBoard();XCTAssertTrue(game.board.blackAtBottom,"Flip Board works in a lesson");model.learning.seek(step:1);game.refresh();XCTAssertTrue(game.board.blackAtBottom,"the flip lasts through the lesson")
    }
    /// B-17: Game ▸ Resign is offered only when resigning does something: once a move is played, until the game ends.
    func testResignIsOfferedOnlyWhenThereIsAGameToResign()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let resign={game.validateMenuItem(NSMenuItem(title:"Resign…",action:#selector(GameWindow.resign),keyEquivalent:""))}
        model.practice();model.session.cancelWork();game.refresh();XCTAssertFalse(resign(),"no move played yet")
        try model.session.playWhite(from:"e2",to:"e4");model.session.cancelWork();XCTAssertTrue(resign())
        model.session.resign();XCTAssertNotNil(model.session.state.practice.ending);XCTAssertFalse(resign(),"the game is over")
    }
    /// B-6: a review of the learner's own game opens from the learner's side; an imported game from White's.
    func testAReviewOpensFromTheLearnersSide()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"b");model.session.cancelWork()
        model.reviewCurrent();for _ in 0..<300 where !model.review.active{try await Task.sleep(for:.milliseconds(10))}
        let document=try XCTUnwrap(model.review.document);XCTAssertEqual(model.reviewLearnerSide(document),"b")
        game.refresh();XCTAssertTrue(game.board.blackAtBottom,"the learner played Black")
        game.flipBoard();XCTAssertFalse(game.board.blackAtBottom,"Flip Board works in a review")
        model.importReviewData(Data("[White \"Ana\"]\n[Black \"Ben\"]\n\n1. e4 e5 *\n".utf8))
        for _ in 0..<300 where model.review.document?.id==document.id || !model.review.active{try await Task.sleep(for:.milliseconds(10))}
        let imported=try XCTUnwrap(model.review.document);XCTAssertNil(model.reviewLearnerSide(imported));game.refresh();XCTAssertFalse(game.board.blackAtBottom,"an imported game opens from White's side")
    }
    /// B-6: the learner's side is saved with the review, so a saved review reopened after a restart opens from it.
    func testASavedReviewReopensFromTheLearnersSideAfterARestart()async throws {
        var model:NativeModel?=try NativeModel()
        model!.practice();model!.session.newGame(side:"b");model!.session.cancelWork()
        model!.reviewCurrent();for _ in 0..<300 where !model!.review.active{try await Task.sleep(for:.milliseconds(10))}
        let id=try XCTUnwrap(model!.review.document?.id);model!.saveCurrentReview()
        XCTAssertEqual(try model!.reviewStore.load(id).learnerSide,"b","the side is saved with the review");model!.shutdown();model=nil
        let restarted=try NativeModel(),game=GameWindow(model:restarted);defer{game.window?.delegate=nil;restarted.shutdown()}
        restarted.openSavedReview(id);for _ in 0..<300 where !restarted.review.active{try await Task.sleep(for:.milliseconds(10))}
        let document=try XCTUnwrap(restarted.review.document);XCTAssertEqual(restarted.reviewLearnerSide(document),"b")
        game.refresh();XCTAssertTrue(game.board.blackAtBottom,"the reopened review opens from Black's side")
    }
    /// B-6: the learner's side round-trips through the store, survives a cursor-only save, and a save written before
    /// the field existed (or with a value it cannot hold) reads as no side: White at the bottom, as before.
    func testTheReviewStoreKeepsTheLearnersSideAndReadsOldSaves()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],store=ReviewStore(directory:root)
        try store.save(document,cursor:0,branches:[],learnerSide:"b");XCTAssertEqual(try ReviewStore(directory:root).load(document.id).learnerSide,"b")
        try store.save(document,cursor:1,branches:[],learnerSide:"b");let reread=try ReviewStore(directory:root).load(document.id);XCTAssertEqual(reread.learnerSide,"b");XCTAssertEqual(reread.cursor,1)
        try store.save(document,cursor:1,branches:[],learnerSide:"w");XCTAssertEqual(try ReviewStore(directory:root).load(document.id).learnerSide,"w","a changed side is written, not skipped as a cursor-only save")
        let url=root.appendingPathComponent(document.id.uuidString+".json")
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:try Data(contentsOf:url)) as? [String:Any]);old["learnerSide"]=nil
        try JSONSerialization.data(withJSONObject:old).write(to:url);XCTAssertNil(try ReviewStore(directory:root).load(document.id).learnerSide,"an old save has no side")
        old["learnerSide"]="x";try JSONSerialization.data(withJSONObject:old).write(to:url);XCTAssertNil(try ReviewStore(directory:root).load(document.id).learnerSide,"a value that is not a side is ignored")
    }
    /// B-17: Hint sits in the Game menu on ⇧⌘H, and Flip Board on ⇧⌘F; neither collides with another shortcut.
    func testTheGameMenuCarriesHintAndFlipShortcuts(){
        let menu=AppDelegate.makeGameMenu(target:nil)
        let hint=menu.items.first{$0.action == #selector(GameWindow.barHint)},flip=menu.items.first{$0.action == #selector(GameWindow.flipBoard)}
        XCTAssertEqual(hint?.title,"Hint");XCTAssertEqual(hint?.keyEquivalent,"h");XCTAssertEqual(hint?.keyEquivalentModifierMask,[.command,.shift])
        XCTAssertEqual(flip?.keyEquivalent,"f");XCTAssertEqual(flip?.keyEquivalentModifierMask,[.command,.shift])
        let keys=menu.items.filter{!$0.keyEquivalent.isEmpty}.map{"\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)"};XCTAssertEqual(keys.count,Set(keys).count,"no shortcut twice")
    }
    /// B-14: lowercase coordinates on two edges, files below and ranks to the left, centred in the margin by their
    /// measured size and never over the board.
    func testCoordinatesSitOnTwoEdgesCentredByMeasure(){
        let board=NSRect(x:20,y:20,width:400,height:400),size:(String)->NSSize={NSSize(width:$0=="f" ? 4:7,height:13)}
        let labels=BoardView.coordinateLabels(board:board,blackAtBottom:false,margin:20,size:size)
        XCTAssertEqual(labels.map(\.text),["a","b","c","d","e","f","g","h","1","2","3","4","5","6","7","8"])
        for (i,label) in labels.prefix(8).enumerated(){let w=size(label.text).width;XCTAssertEqual(label.origin.x+w/2,board.minX+(CGFloat(i)+0.5)*50,accuracy:0.001);XCTAssertEqual(label.origin.y,(20-13)/2,accuracy:0.001);XCTAssertLessThanOrEqual(label.origin.y+13,board.minY)}
        for (i,label) in labels.suffix(8).enumerated(){XCTAssertEqual(label.origin.y+6.5,board.minY+(CGFloat(i)+0.5)*50,accuracy:0.001);XCTAssertEqual(label.origin.x+7/2,10,accuracy:0.001);XCTAssertLessThanOrEqual(label.origin.x+7,board.minX)}
        XCTAssertEqual(BoardView.coordinateLabels(board:board,blackAtBottom:true,margin:20,size:size).map(\.text),["h","g","f","e","d","c","b","a","8","7","6","5","4","3","2","1"])
    }
    /// B-15: the check glow is saturated and its ring stands out from the glow and the square; the last-move tint is
    /// a hue that is plainly visible, and pieces stay readable on it, in every board theme.
    func testCheckGlowAndLastMoveTintHaveContrastInEveryTheme(){
        func luminance(_ color:NSColor)->Double {
            let c=color.usingColorSpace(.sRGB)!;func linear(_ x:CGFloat)->Double {let v=Double(x);return v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
            return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
        }
        func contrast(_ a:NSColor,_ b:NSColor)->Double {let x=luminance(a),y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)}
        func over(_ base:NSColor,_ top:NSColor,_ alpha:CGFloat)->NSColor {let b=base.usingColorSpace(.sRGB)!,t=top.usingColorSpace(.sRGB)!;return NSColor(srgbRed:b.redComponent*(1-alpha)+t.redComponent*alpha,green:b.greenComponent*(1-alpha)+t.greenComponent*alpha,blue:b.blueComponent*(1-alpha)+t.blueComponent*alpha,alpha:1)}
        func distance(_ a:NSColor,_ b:NSColor)->CGFloat {let x=a.usingColorSpace(.sRGB)!,y=b.usingColorSpace(.sRGB)!;return sqrt(pow(x.redComponent-y.redComponent,2)+pow(x.greenComponent-y.greenComponent,2)+pow(x.blueComponent-y.blueComponent,2))}
        XCTAssertGreaterThanOrEqual(BoardPalette.check.usingColorSpace(.sRGB)!.saturationComponent,0.8,"the check glow is saturated")
        XCTAssertGreaterThan(BoardOverlay.checkGlow,BoardOverlay.annotationFill,"stronger than an ordinary mark")
        for theme in AppSettings.themes.keys.sorted() {
            let p=BoardPalette.theme(theme)
            for square in [p.lightSquare,p.darkSquare] {
                XCTAssertGreaterThanOrEqual(contrast(BoardPalette.checkRing,square),3,"\(theme): the check ring against the square")
                XCTAssertGreaterThanOrEqual(contrast(BoardPalette.checkRing,over(square,BoardPalette.check,BoardOverlay.checkGlow)),3,"\(theme): the check ring against its glow")
                let tinted=over(square,BoardPalette.lastMove,BoardOverlay.lastMoveTint)
                XCTAssertGreaterThanOrEqual(distance(tinted,square),0.15,"\(theme): the last move is plainly tinted")
                XCTAssertGreaterThanOrEqual(contrast(BoardPalette.darkPiece,tinted),4.5,"\(theme): a black piece stays readable on the tint")
                XCTAssertGreaterThanOrEqual(contrast(BoardPalette.pieceOutline,tinted),4.5,"\(theme): a white piece's outline stays readable on the tint")
            }
        }
    }
    /// B-18: the New Game sheet offers White, Black or a random side, and the opponent strengths Settings offers.
    func testNewGameChoicesOfferRandomSideAndStrength(){
        XCTAssertEqual(NewGameChoices.sides.map(\.title),["Play as White","Play as Black","Random Side"])
        XCTAssertEqual(NewGameChoices.side(at:0){true},"w");XCTAssertEqual(NewGameChoices.side(at:1){true},"b")
        XCTAssertEqual(NewGameChoices.side(at:2){true},"w");XCTAssertEqual(NewGameChoices.side(at:2){false},"b")
        let titles=NewGameChoices.strengths.map(\.title),tags=NewGameChoices.strengths.map(\.tag)
        XCTAssertEqual(Array(tags.suffix(3)),["gentle","club","custom"]);XCTAssertEqual(Array(titles.suffix(3)),["Gentle","Club","Keep Custom Settings"])
        XCTAssertEqual(tags.contains("first_steps"),ReviewRolloutPolicy.beginnerOpponentEnabled)
        var settings=AppSettings();settings.opponentPreset="club";XCTAssertEqual(NewGameChoices.strengths[NewGameChoices.strengthIndex(settings)].tag,"club")
        settings.opponentPreset="first_steps";XCTAssertEqual(NewGameChoices.strengths[NewGameChoices.strengthIndex(settings)].tag,ReviewRolloutPolicy.beginnerOpponentEnabled ? "first_steps":"custom")
    }
}
