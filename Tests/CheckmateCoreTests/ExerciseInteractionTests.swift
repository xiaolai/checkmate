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
    @MainActor func testAll87PuzzlesThroughPlayer()throws {
        let library=try CourseLibrary()
        for puzzle in library.puzzles {let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);player.openPuzzle(id:puzzle.id);try solve(puzzle.exercise,player);XCTAssertTrue(player.passed,puzzle.id);XCTAssertTrue(session.state.puzzles[puzzle.id]?.solved==true,puzzle.id)}
    }
}
