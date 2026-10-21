import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// The bottom control bar, state by state: what shows, where, and what each control is for.
@MainActor final class ControlBarModelTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func bar(_ model:NativeModel,voice:ControlBarVoice = .off(unavailable:nil))->ControlBarModel {
        ControlBarModel.make(session:model.session,learning:model.learning,review:model.review,training:model.training,voice:voice)
    }
    private func index(_ model:NativeModel,_ id:String)throws -> Int {try XCTUnwrap(model.learning.library.lessons.firstIndex{$0.id==id})}

    /// Every step of a lesson, its exercise step included, has the same four playback slots in the same order, so
    /// none of them moves while the learner steps through; the exercise adds its tools at the trailing edge only.
    func testLessonPlaybackSlotsAreTheSameOnEveryStep()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let castling=try index(model,"castling");model.lesson(castling);model.learning.pause()
        let slot:(ControlBarAction)->Int={switch $0{case .stepFromStart:return 0;case .previousStep,.previousLesson:return 1;case .playPause:return 2;default:return 3}}
        for step in 0..<model.learning.current.beats.count {
            model.learning.seek(step:step);let shown=bar(model)
            XCTAssertEqual(shown.centre.map{slot($0.action)},[0,1,2,3],"step \(step)");XCTAssertFalse(shown.statusInCentre)
            XCTAssertTrue(shown.centre.allSatisfy{$0.symbol != nil},"playback slots are icons")
            if model.learning.attemptStep {
                XCTAssertEqual(shown.trailing.map(\.action),[.attemptHint,.attemptUndo,.attemptRestart])
                XCTAssertEqual(shown.status,.turn(side:"w",label:"Your turn"))
            } else {
                XCTAssertTrue(shown.trailing.isEmpty,"step \(step)")
                guard case .text(let text)?=shown.status else{return XCTFail("step \(step): no step status")}
                XCTAssertTrue(text.hasPrefix("Step \(step+1) of \(model.learning.current.beats.count)"),text)
            }
        }
    }
    /// At a lesson's edges the arrow keeps its slot but doubles, and its label, the status and the menu name the lesson.
    func testLessonBoundariesNameTheLessonTheArrowGoesTo()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let rook=try index(model,"rook");model.lesson(rook);model.learning.pause()
        var shown=bar(model)
        let previous=try XCTUnwrap(shown.item(.previousLesson));XCTAssertEqual(previous.symbol,"chevron.backward.2");XCTAssertEqual(previous.label,"Previous lesson: The Pawn")
        XCTAssertEqual(shown.status,.text("Step 1 of \(model.learning.current.beats.count) · back: The Pawn"))
        model.learning.seek(step:model.learning.current.beats.count-1);shown=bar(model)
        let next=try XCTUnwrap(shown.item(.nextLesson));XCTAssertEqual(next.symbol,"chevron.forward.2");XCTAssertEqual(next.label,"Next lesson: The Bishop")
        XCTAssertEqual(shown.status,.text("Step \(model.learning.current.beats.count) of \(model.learning.current.beats.count) · next: The Bishop"))
        model.lesson(0);model.learning.pause();XCTAssertEqual(bar(model).item(.previousStep)?.enabled,false,"the first lesson has nothing before it")
    }
    /// An exercise whose computer turn waits after the learner left offers Resume at the leading edge.
    func testAWaitingExerciseOffersResume()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let castling=try index(model,"castling");model.lesson(castling);model.learning.pause();model.learning.goToAttempt()
        XCTAssertNil(bar(model).item(.resumeAttempt))
        XCTAssertEqual(bar(model).item(.attemptUndo)?.enabled,false);XCTAssertEqual(bar(model).item(.attemptHint)?.label,"Hint")
        model.learning.click("e1");model.learning.click("g1")
        XCTAssertEqual(bar(model).item(.attemptUndo)?.enabled,true);XCTAssertEqual(bar(model).item(.attemptRestart)?.enabled,true)
    }
    /// Practice puts the turn in the centre, New game at the leading edge and the game's help at the trailing edge,
    /// with the voice coach as its own group; a held game is resumed by a named button, never a play symbol.
    func testPracticeStatusSitsInTheCentreWithNamedRecovery()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.practice();model.session.cancelWork()
        let shown=bar(model)
        XCTAssertTrue(shown.statusInCentre);XCTAssertEqual(shown.status,.turn(side:"w",label:"White to move"))
        XCTAssertEqual(shown.leading.map(\.action),[.newGame]);XCTAssertEqual(shown.leading.first?.label,"New game…");XCTAssertNil(shown.leading.first?.symbol)
        XCTAssertEqual(shown.trailing.map(\.action),[.takeBack,.hint,.tryMove]);XCTAssertNil(shown.item(.tryMove)?.symbol,"Try a move is said in words")
        XCTAssertEqual(shown.trailingGroups.map{$0.map(\.action)},[[.voiceConnect]])
        let on=bar(model,voice:.on(microphone:true,canStop:true))
        XCTAssertEqual(on.trailingGroups.first?.map(\.action),[.voiceStop,.voiceMicrophone],"Stop stays one click away");XCTAssertEqual(on.item(.voiceMicrophone)?.menu.map(\.action),[.voiceDisconnect])
        XCTAssertEqual(bar(model,voice:.connecting("Asking for the microphone…")).status,.working("Connecting voice coach"),"the long progress goes to Cancel's tooltip")
        XCTAssertEqual(bar(model,voice:.connecting("Asking for the microphone…")).item(.voiceCancel)?.detail,"Asking for the microphone…")
        XCTAssertEqual(bar(model,voice:.off(unavailable:.companionConnected)).item(.voiceConnect)?.enabled,false)
        XCTAssertEqual(bar(model).item(.voiceConnect)?.label,"Connect voice coach")
    }
    /// V-10: an unavailable coach says why in plain words, for its tooltip and for VoiceOver alike.
    func testUnavailableVoiceSaysWhy()throws {
        let model=try NativeModel();defer{model.shutdown()}
        for reason:VoiceUnavailability in [.companionConnected,.practiceOnly,.trainingGameOnly,.networkGame] {
            let item=try XCTUnwrap(bar(model,voice:.off(unavailable:reason)).item(.voiceConnect))
            XCTAssertFalse(item.enabled);XCTAssertEqual(item.label,reason.message);XCTAssertFalse(item.label.contains("MCP"))
        }
        XCTAssertEqual(bar(model,voice:.off(unavailable:.companionConnected)).item(.voiceConnect)?.label,"Voice is unavailable while Codex is connected to Checkmate.")
        model.session.setConnection(enabled:true,role:"coach",lease:"companion")
        XCTAssertEqual(model.voice.practiceVoiceUnavailability,.companionConnected,"the bar's reason comes from the coach")
    }
    /// Over a coach demonstration the voice coach keeps its controls: Stop stays one click away, Cancel while connecting.
    func testVoiceControlsStayOverADemonstration()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.practice();model.session.cancelWork()
        try model.session.demonstrate(title:"Line",introduction:"Imagine",lines:[DemoLineInput(label:"Main",moves:[DemoStepInput(uci:"e2e4")])])
        let shown=bar(model,voice:.on(microphone:true,canStop:true))
        XCTAssertEqual(shown.centre.map(\.action),[.demoPrevious,.demoPlayPause,.demoNext]);XCTAssertEqual(shown.item(.returnToGame)?.prominent,true)
        XCTAssertEqual(shown.trailingGroups.first?.map(\.action),[.voiceStop,.voiceMicrophone])
        XCTAssertNotNil(bar(model,voice:.connecting("…")).item(.voiceCancel))
    }
    /// A mini-game says where Back goes, in words.
    func testMiniGameBackNamesItsOrigin()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let pawn=try index(model,"pawn");model.lesson(pawn);model.learning.startPawnDuel(computer:false)
        let shown=bar(model)
        XCTAssertEqual(shown.leading.first?.label,"Back to The Pawn");XCTAssertNil(shown.leading.first?.symbol)
        XCTAssertEqual(shown.trailing.map(\.action),[.miniUndo,.miniNewGame]);XCTAssertTrue(shown.statusInCentre)
    }
    /// A review has its five playback controls; an imagined branch adds a named way back to the original.
    func testReviewShowsReturnToOriginalOnlyInABranch()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8))[0])
        var shown=bar(model)
        XCTAssertEqual(shown.centre.map(\.action),[.reviewFirst,.reviewPrevious,.reviewPlayPause,.reviewNext,.reviewLast]);XCTAssertNil(shown.item(.returnToOriginal))
        XCTAssertEqual(shown.status,.text("Original game"))
        try model.review.select(1);try model.review.beginBranch();shown=bar(model)
        XCTAssertEqual(shown.status,.text("Imagined line"));XCTAssertEqual(shown.item(.returnToOriginal)?.prominent,true)
    }

    /// The row decision: the centre stays centred while both sides fit beside it; a long status never forces a
    /// second row, a leading status keeps its minimum only when nothing else leads, and wide sides take two rows.
    func testRowsDependOnControlsNotOnStatusLength(){
        let lesson=ControlBarModel(status:.text(String(repeating:"long lesson name ",count:20)),centre:[ControlBarItem(action:.playPause,label:"Play")])
        XCTAssertTrue(ControlBarView.fitsOneRow(lesson,leading:0,centre:170,trailing:0,width:568),"the status shortens instead")
        XCTAssertTrue(ControlBarView.fitsOneRow(lesson,leading:0,centre:170,trailing:0,width:400),"101 pt is room enough for the status's 72 pt minimum")
        XCTAssertFalse(ControlBarView.fitsOneRow(lesson,leading:0,centre:170,trailing:0,width:300),"51 pt is not")
        var resume=lesson;resume.leading=[ControlBarItem(action:.resumeAttempt,label:"Resume your attempt",prominent:true)]
        XCTAssertTrue(ControlBarView.fitsOneRow(resume,leading:150,centre:170,trailing:110,width:748),"Resume does not add a row")
        let practice=ControlBarModel(status:.turn(side:"w",label:"White to move"),statusInCentre:true)
        XCTAssertTrue(ControlBarView.fitsOneRow(practice,leading:95,centre:120,trailing:230,width:728))
        XCTAssertFalse(ControlBarView.fitsOneRow(practice,leading:95,centre:120,trailing:230,width:560),"wide sides take two rows")
        XCTAssertEqual(ControlBarView.rows(practice,leading:95,centre:120,trailing:230,width:560),2,"the sides fit side by side above the centre")
        XCTAssertEqual(ControlBarView.rows(practice,leading:95,centre:120,trailing:230,width:288),3,"at the narrowest each side takes its own row")
        XCTAssertEqual(ControlBarView.rows(practice,leading:95,centre:120,trailing:230,width:340),3,"95 + 230 + two gaps is 353 pt")
        XCTAssertEqual(ControlBarView.rows(practice,leading:95,centre:120,trailing:230,width:353),2)
    }
    /// One symbol, one meaning, across every state the tests above reach: a look-alike pair such as replay and undo
    /// cannot come back by giving one symbol two jobs. (It cannot judge two different symbols that look alike; the
    /// symbols chosen are distinct shapes.)
    func testEachSymbolHasOneMeaning()throws {
        let meaning:[ControlBarAction:String]=[
            .stepFromStart:"to the start",.previousStep:"step back",.demoPrevious:"step back",.previewPrevious:"step back",.reviewPrevious:"step back",
            .nextStep:"step on",.demoNext:"step on",.previewNext:"step on",.reviewNext:"step on",
            .previousLesson:"previous lesson",.nextLesson:"next lesson",
            .playPause:"playback",.demoPlayPause:"playback",.reviewPlayPause:"playback",
            .attemptUndo:"undo",.takeBack:"undo",.miniUndo:"undo",.trainingTakeBack:"undo",
            .attemptRestart:"start again",.miniNewGame:"start again",.trainingTryAgain:"start again",
            .attemptHint:"hint",.hint:"hint",.trainingHint:"hint",
            .reviewFirst:"to the start",.reviewLast:"last",.puzzleLibrary:"library",.trainingLibrary:"library",
            .voiceConnect:"voice",.voiceMicrophone:"voice",.voiceStop:"stop speaking",
        ]
        let model=try NativeModel();defer{model.shutdown()}
        var states:[ControlBarModel]=[]
        let castling=try index(model,"castling");model.lesson(castling);model.learning.pause()
        for step in 0..<model.learning.current.beats.count{model.learning.seek(step:step);states.append(bar(model))}
        model.practice();states+=[bar(model),bar(model,voice:.on(microphone:false,canStop:false))]
        let pawn=try index(model,"pawn");model.lesson(pawn);model.learning.startPawnDuel(computer:false);states.append(bar(model))
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]);states.append(bar(model))
        var seen:[String:Set<String>]=[:]
        for item in states.flatMap(\.items) where item.symbol != nil {
            let kind=try XCTUnwrap(meaning[item.action],"\(item.action) has an icon but no declared meaning")
            let symbol=item.symbol!.replacingOccurrences(of:".fill",with:"").replacingOccurrences(of:"pause",with:"play").replacingOccurrences(of:"mic.slash",with:"mic")
            seen[symbol,default:[]].insert(kind)
        }
        for (symbol,kinds) in seen{XCTAssertEqual(kinds.count,1,"\(symbol) means \(kinds.sorted())")}
        XCTAssertNotEqual(seen["arrow.counterclockwise"],seen["arrow.uturn.backward"])
    }
}
