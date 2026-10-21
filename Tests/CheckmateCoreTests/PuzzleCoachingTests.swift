import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// Puzzles coach before they reveal, a set ends with a summary instead of starting over, a lesson leads to the
/// puzzles that check it, and the course says how far the learner has come.
final class PuzzleCoachingTests:XCTestCase {
    @MainActor private func player()throws -> (GameSession,LearningPlayer) {let s=try GameSession(engine:nil);return (s,try LearningPlayer(session:s))}

    /// A move puzzle's first hint highlights the piece to move, its second says what to look for; then only Reveal is left.
    /// A correct answer after a hint is an assisted solve, recorded with its hint count.
    @MainActor func testAMovePuzzleHintLadderEndsAtRevealAndIsRecorded()throws {
        let (s,p)=try player();defer{p.shutdown()}
        p.openPuzzle(id:"extra-1");XCTAssertTrue(p.canHint);XCTAssertEqual(p.puzzleHints,0);XCTAssertTrue(p.hintTexts.isEmpty)
        p.hint();XCTAssertEqual(p.puzzleHints,1);XCTAssertTrue(p.frame.hl.contains(Highlight(sq:"f3",kind:"hint")));XCTAssertEqual(p.hintTexts,["Move the highlighted piece."])
        p.hint();XCTAssertEqual(p.hintTexts.count,2);XCTAssertEqual(p.hintTexts[1],"Look for a capture where no enemy piece can take your piece back.");XCTAssertFalse(p.canHint,"after the ladder, Reveal is what is left")
        p.hint();XCTAssertEqual(p.puzzleHints,2)
        p.click("f3");p.click("h4");XCTAssertTrue(p.passed);XCTAssertTrue(p.feedback.hasPrefix("Correct, with help from a hint. It counts as solved with help and comes back for review. "),p.feedback)
        let record=try XCTUnwrap(s.state.puzzles["extra-1"]);XCTAssertEqual(record.hints,2);XCTAssertFalse(record.solved);XCTAssertTrue(record.countsAsSolved);XCTAssertTrue(record.review);XCTAssertEqual(record.standing,.solvedWithHints)
        p.filter = .unsolved;XCTAssertFalse(p.filteredPuzzles.contains{$0.id=="extra-1"},"an assisted solve counts as solved")
        p.filter = .review;XCTAssertTrue(p.filteredPuzzles.contains{$0.id=="extra-1"},"and it comes back for review");p.filter = .all
        p.openPuzzle(id:"extra-1");XCTAssertEqual(p.puzzleHints,0,"each visit starts without hints");XCTAssertFalse(p.frame.hl.contains{$0.kind=="hint"})
    }
    /// A choice puzzle's hint rules out a wrong choice; squares and path puzzles say what to look for.
    @MainActor func testEveryPuzzleKindHasAHintBeforeReveal()throws {
        let (_,p)=try player();defer{p.shutdown()}
        p.openPuzzle(id:"course:intro:1");p.hint();XCTAssertEqual(p.hintTexts,["It is not “Black”."]);XCTAssertFalse(p.canHint)
        p.openPuzzle(id:"extra-4");p.hint();XCTAssertEqual(p.hintTexts,["For each piece, ask whether a piece of its own side could capture back if it were taken."]);XCTAssertFalse(p.canHint)
        p.openPuzzle(id:"course:safe-squares:1");p.hint();XCTAssertEqual(p.hintTexts,["Move the highlighted king one step at a time."]);XCTAssertTrue(p.frame.hl.contains(Highlight(sq:"a1",kind:"hint")))
        p.hint();XCTAssertEqual(p.hintTexts.last,"Before each step, check that no enemy piece attacks the square.")
        for puzzle in p.library.puzzles {p.openPuzzle(id:puzzle.id);XCTAssertTrue(p.canHint,puzzle.id);p.hint();XCTAssertFalse(p.hintTexts.isEmpty,puzzle.id);XCTAssertFalse(p.hintTexts.contains{$0.isEmpty},puzzle.id)}
        p.openPuzzle(id:"course:intro:1");p.choose("White");XCTAssertTrue(p.passed);XCTAssertFalse(p.canHint,"a solved puzzle needs no hint")
    }
    /// Skip moves on and records nothing: the skipped puzzle stays not tried and is not marked for review.
    @MainActor func testSkipLeavesThePuzzleUntried()throws {
        let (s,p)=try player();defer{p.shutdown()}
        p.openPuzzle(id:"course:intro:1");p.skip();XCTAssertNil(s.state.puzzles["course:intro:1"]);XCTAssertNotEqual(p.activePuzzle?.id,"course:intro:1");XCTAssertNotNil(p.activePuzzle)
    }
    /// The end of a set shows a summary instead of starting the set again; Review Mistakes opens the ones to review.
    @MainActor func testTheEndOfASetShowsASummaryAndReviewMistakes()throws {
        let (s,p)=try player();defer{p.shutdown()}
        p.topic="Introduction";let set=p.filteredPuzzles;XCTAssertEqual(set.count,2)
        p.openPuzzle(id:set[0].id);p.reveal();p.next();XCTAssertEqual(p.activePuzzle?.id,set[1].id);XCTAssertNil(p.setSummary)
        p.skip();XCTAssertNil(p.activePuzzle,"the set does not start over");XCTAssertEqual(s.activity.place,.puzzleLibrary)
        let summary=try XCTUnwrap(p.setSummary);XCTAssertEqual(summary,PuzzleSetSummary(total:2,solved:0,helped:0,toReview:1,notTried:1))
        XCTAssertEqual(summary.text,"0 of 2 solved on your own. 1 to review. 1 not tried.")
        p.reviewMistakes();XCTAssertEqual(p.filter,.review);XCTAssertEqual(p.activePuzzle?.id,set[0].id);XCTAssertNil(p.setSummary)
        p.openPuzzle(id:set[0].id);XCTAssertNil(p.setSummary,"opening a puzzle clears the summary")
    }
    /// Check Yourself opens the first puzzle linked to the lesson by its id, with the library filtered to that lesson.
    @MainActor func testCheckYourselfOpensTheLessonsOwnPuzzles()throws {
        let (_,p)=try player();defer{p.shutdown()}
        let fork=try XCTUnwrap(p.library.lessons.firstIndex{$0.id=="fork"});XCTAssertEqual(p.library.puzzles(for:"fork").map(\.id),["course:fork:1","course:fork:2","extra-2"])
        XCTAssertEqual(p.checkYourselfTitle(index:fork),"Check Yourself: 3 Puzzles")
        p.level="Developing";p.filter = .review;p.query="zzz"
        p.checkYourself(index:fork);XCTAssertEqual(p.activePuzzle?.id,"course:fork:1");XCTAssertEqual(p.topic,"The Fork");XCTAssertNil(p.level);XCTAssertEqual(p.filter,.all);XCTAssertEqual(p.query,"")
        let intro=try XCTUnwrap(p.library.lessons.firstIndex{$0.id=="intro"});XCTAssertEqual(p.checkYourselfTitle(index:intro),"Check Yourself: 2 Puzzles")
        let practice=try XCTUnwrap(p.library.lessons.firstIndex{$0.id=="pawn-duel"})
        if p.library.puzzles(for:"pawn-duel").isEmpty {XCTAssertNil(p.checkYourselfTitle(index:practice),"no puzzles, no button")}
    }
    /// The topic picker groups topics by course section, levels come from the course, and a saved filter the course no
    /// longer offers (an old topic name) falls back to all.
    @MainActor func testTopicsAreGroupedBySectionAndUnknownFiltersFallBack()throws {
        let (s,p)=try player();defer{p.shutdown()}
        let groups=p.topicGroups;XCTAssertEqual(groups.first?.title,"Getting Started");XCTAssertEqual(groups.first?.topics,["Introduction","The Chessboard"])
        XCTAssertEqual(groups.flatMap(\.topics).count,Set(p.library.puzzles.map(\.topic)).count);XCTAssertTrue(groups.allSatisfy{!$0.topics.isEmpty})
        XCTAssertEqual(p.levels,["Foundation","Developing"])
        s.state.puzzleFilters=["topic":"Forks","level":"Expert","status":"All","query":""];p.reloadFilters();XCTAssertNil(p.topic);XCTAssertNil(p.level)
        let restored=try LearningPlayer(session:s);defer{restored.shutdown()};XCTAssertNil(restored.topic);XCTAssertNil(restored.level)
        s.state.puzzleFilters=["topic":"The Fork","level":"Developing"];p.reloadFilters();XCTAssertEqual(p.topic,"The Fork");XCTAssertEqual(p.level,"Developing")
    }
    /// The course says how many main lessons are explored, where to continue, and when the whole course is done.
    @MainActor func testCourseProgressContinueAndCompletion()throws {
        let (s,p)=try player();defer{p.shutdown()}
        let main=p.library.lessons.filter{!$0.isPractice}.map(\.id);XCTAssertEqual(main.count,34)
        XCTAssertEqual(p.courseProgress.explored,0);XCTAssertEqual(p.courseProgress.total,34);XCTAssertEqual(p.courseProgress.text,"0 of 34")
        XCTAssertEqual(p.continueIndex,0,"a new learner starts at the first lesson");XCTAssertFalse(p.courseComplete)
        s.state.course.lessonID="rook";s.state.course.completed=["intro","board","pawn"];XCTAssertEqual(p.continueIndex,p.library.lessons.firstIndex{$0.id=="rook"},"the bookmark, not finished yet")
        XCTAssertEqual(p.courseProgress.explored,3)
        s.state.course.completed.append("rook");XCTAssertEqual(p.continueIndex,p.library.lessons.firstIndex{$0.id=="bishop"},"after a finished bookmark, the next unexplored main lesson")
        s.state.course.completed=main.filter{$0 != "board"};s.state.course.lessonID="famous-game";XCTAssertEqual(p.continueIndex,1,"a gap earlier in the course")
        s.state.course.completed=main;XCTAssertNil(p.continueIndex);XCTAssertTrue(p.courseComplete);XCTAssertEqual(p.courseProgress.text,"34 of 34")
        s.state.course.completed=main+["pawn-duel","unknown"];XCTAssertEqual(p.courseProgress.explored,34,"practice and unknown lessons are not counted")
    }
}
