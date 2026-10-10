import XCTest
@testable import CheckmateCore
final class ExerciseInteractionTests:XCTestCase {
    @MainActor func solve(_ e:Exercise,_ p:LearningPlayer)throws {
        switch e.kind {
        case "choice":p.choose(e.answer!)
        case "squares":if (e.answers ?? []).isEmpty{p.noSquares()}else{for sq in e.answers!{p.click(sq)};p.checkAnswer()}
        case "move":p.click(e.from!);p.click(e.to!)
        case "path":
            let start=e.from!,goal=e.to!,initial=p.frame.board!;var queue:[(String,Position,[String])]=[(start,initial,[])],visited=Set([start]);var route:[String]?
            while !queue.isEmpty {let (sq,board,path)=queue.removeFirst();if sq==goal{route=path;break};for to in ChessRules.squares where !visited.contains(to) && CourseLibrary.safeKingStep(board,from:sq,to:to){var next=board;try CourseLibrary.apply(&next,moves:[[sq,to]]);visited.insert(to);queue.append((to,next,path+[to]))}}
            p.click(start);for square in try XCTUnwrap(route){p.click(square)}
        default:XCTFail("Unknown exercise kind \(e.kind)")
        }
    }
    @MainActor func testAll83AuthoredQuizzesThroughPlayer()async throws {
        let library=try CourseLibrary()
        for (key,e) in library.exercises {let session=try GameSession(engine:nil),player=try LearningPlayer(session:session,answerFeedbackDelay:.zero);let parts=key.split(separator:":");let index=try XCTUnwrap(library.lessons.firstIndex{$0.id==String(parts[0])});let quizStep=Int(parts[1])!;player.openLesson(index:index);player.seek(step:quizStep);try solve(e,player);XCTAssertTrue(player.passed,key)
            for _ in 0..<100{if player.step != quizStep || session.state.course.completed.contains(player.current.id){break};try await Task.sleep(for:.milliseconds(1))}
            XCTAssertTrue(session.state.course.answered.contains(key),key)
            if quizStep<player.current.beats.count-1{XCTAssertEqual(player.step,quizStep+1,key);XCTAssertTrue(player.playing,key)}else{XCTAssertTrue(session.state.course.completed.contains(player.current.id),key);XCTAssertFalse(player.playing,key)}
            player.shutdown()}
    }
    @MainActor func testAll87PuzzlesThroughPlayer()throws {
        let library=try CourseLibrary()
        for puzzle in library.puzzles {let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);player.openPuzzle(id:puzzle.id);try solve(puzzle.exercise,player);XCTAssertTrue(player.passed,puzzle.id);XCTAssertTrue(session.state.puzzles[puzzle.id]?.solved==true,puzzle.id)}
    }
}
