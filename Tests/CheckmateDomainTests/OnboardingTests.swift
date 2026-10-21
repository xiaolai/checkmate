import XCTest
@testable import CheckmateDomain

/// The first-run welcome (L-20): only for a learner with no saved progress, never for a test run that did not ask for it,
/// and each placement starts at the beginning of a part of the course.
final class OnboardingTests:XCTestCase {
    func testItShowsOnlyOnATrueFirstRunOrWhenATestAsks(){
        XCTAssertTrue(Onboarding.shows(firstRun:true,silent:false,requested:false))
        XCTAssertFalse(Onboarding.shows(firstRun:false,silent:false,requested:false),"an existing save never sees it")
        XCTAssertFalse(Onboarding.shows(firstRun:true,silent:true,requested:false),"an automation or test run never sees it unasked")
        XCTAssertTrue(Onboarding.shows(firstRun:false,silent:true,requested:true),"a test that asks for it gets it")
    }
    func testTheStepsAreLanguageAndVoiceThenPlacementThenFirstMove(){
        XCTAssertEqual(Onboarding.Step.allCases,[.languageAndVoice,.placement,.firstMove])
        XCTAssertEqual(Onboarding.Step.languageAndVoice.next,.placement);XCTAssertEqual(Onboarding.Step.placement.next,.firstMove);XCTAssertNil(Onboarding.Step.firstMove.next)
        XCTAssertNil(Onboarding.Step.languageAndVoice.previous);XCTAssertEqual(Onboarding.Step.firstMove.previous,.placement)
    }
    func testEachPlacementStartsAtTheBeginningOfItsPartOfTheCourse()throws {
        let library=try CourseLibrary(),firsts=Set(library.sections.compactMap(\.lessons.first))
        let indices=try Onboarding.Placement.allCases.map{try XCTUnwrap(Onboarding.lessonIndex($0,in:library),"\($0) names a lesson in the course")}
        for index in indices {XCTAssertTrue(firsts.contains(library.lessons[index].id),"\(library.lessons[index].id) begins a part of the course");XCTAssertFalse(library.lessons[index].isPractice)}
        XCTAssertEqual(indices.first,0,"a new learner starts at the very beginning")
        XCTAssertEqual(indices,indices.sorted());XCTAssertEqual(Set(indices).count,indices.count,"more experience starts later")
        XCTAssertEqual(Onboarding.Placement.allCases.first,.new,"the first choice, selected at the start, is the beginning")
    }
}
