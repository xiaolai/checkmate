import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Mini-game plan WI-021 in the native host: the training game's voice controls appear only with
/// `CHECKMATE_TRAINING_VOICE`, only for a game being played, as practice's do; the coach's highlights draw on the
/// training board only while they belong to the board shown.
@MainActor final class TrainingVoiceNativeTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");unsetenv("CHECKMATE_TRAINING_VOICE");try? FileManager.default.removeItem(at:directory)}
    private func bar(_ model:NativeModel,trainingVoice:Bool)->ControlBarModel {
        ControlBarModel.make(session:model.session,learning:model.learning,review:model.review,training:model.training,network:model.network,voice:.off(unavailable:nil),trainingVoice:trainingVoice)
    }
    func testTheFlagAloneOffersTheTrainingCoach()throws {
        let off=try NativeModel();defer{off.shutdown()}
        off.training?.games.engine=ScriptedDefender();off.startTraining("finish-the-game",variant:"kqk")
        XCTAssertNil(off.trainingVoice,"no adapter without the flag");XCTAssertNil(off.voice.training);XCTAssertFalse(off.voice.trainingVoiceAvailable)
        XCTAssertFalse(bar(off,trainingVoice:false).items.contains{$0.action == .voiceConnect},"the training bar is unchanged")
        setenv("CHECKMATE_TRAINING_VOICE","1",1)
        let model=try NativeModel();defer{model.shutdown()}
        model.training?.games.engine=ScriptedDefender();model.startTraining("finish-the-game",variant:"kqk")
        XCTAssertNotNil(model.voice.training);XCTAssertTrue(model.voice.trainingVoiceAvailable)
        let shown=bar(model,trainingVoice:true)
        XCTAssertEqual(shown.items.filter{$0.action == .voiceConnect}.map(\.symbol),["mic"],"the practice microphone, the same meaning")
        XCTAssertTrue(shown.items.contains{$0.action == .trainingHint},"the game's own tools stay")
        model.trainingLibrary();XCTAssertFalse(bar(model,trainingVoice:true).items.contains{$0.action == .voiceConnect},"no coach in the library")
    }
    func testTheCoachsHighlightsDrawOnlyOnTheirBoard()async throws {
        setenv("CHECKMATE_TRAINING_VOICE","1",1)
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let defender=ScriptedDefender();defender.holding=true;model.training?.games.engine=defender;defer{defender.release()}
        game.board.frame=NSRect(x:0,y:0,width:640,height:640)
        model.startTraining("finish-the-game",variant:"kqk");game.refresh()
        let training=try XCTUnwrap(model.training),adapter=try XCTUnwrap(model.trainingVoice),exercise=try XCTUnwrap(training.exercise)
        let queen=try XCTUnwrap(game.board.position.first{$0.value==exercise.scenario.learner+"q"}?.key)
        try adapter.bind();let ticket=try adapter.disclose([try XCTUnwrap(adapter.liveTicket?.key)])
        _ = try await adapter.call("highlight_squares",args:["squares":[queen],"arrows":[[String]]()],key:ticket.key)
        game.refresh();XCTAssertTrue(game.board.highlights.contains{$0.sq==queen && $0.kind=="focus"},"drawn on the training board")
        XCTAssertTrue(model.session.highlights.isEmpty,"not on the practice board")
        // A move makes them belong to another board: they go.
        let move=try XCTUnwrap(try exercise.current?.outcomes().first{$0.from==queen && !$0.checkmate && !$0.stalemate})
        training.attempt(from:move.from,to:move.to,promotion:nil);game.refresh()
        XCTAssertNil(adapter.shownMarks);XCTAssertFalse(game.board.highlights.contains{$0.kind=="focus"})
    }
}
