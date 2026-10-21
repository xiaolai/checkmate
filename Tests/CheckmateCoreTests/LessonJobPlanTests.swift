import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateContent

private actor PlanTranslator:LessonTranslationProvider {
 let signedIn:Bool
 var translations=0,checks=0
 init(signedIn:Bool){self.signedIn=signedIn}
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {translations+=1;var text=source;text.title="Titre: "+source.title;return TranslationResult(text:text,model:"fixture",turnID:UUID().uuidString,tokens:UsageTokens(total:3))}
 func accountStatus()async throws->String {checks+=1;if !signedIn{throw CheckmateError.unavailable("Sign in to ChatGPT in Codex, then try again.")};return "Fixture account"}
}
private actor PlanRecorder:LessonRecordingProvider {
 var calls=0
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {calls+=1;return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}
/// L-28: Translate or Record for every lesson checks the sign-in first, then says how much it will do before anything
/// is requested; a single lesson starts as before.
@MainActor final class LessonJobPlanTests:XCTestCase {
 private var directory:URL!
 override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
 override func tearDown(){try? FileManager.default.removeItem(at:directory)}
 private func controller(_ translator:PlanTranslator,_ recorder:PlanRecorder=PlanRecorder())throws -> LessonLanguageController {let c=try LessonLanguageController(library:CourseLibrary(),directory:directory,usage:UsageLedger(directory:directory.appendingPathComponent("Usage")),translator:translator,recorder:recorder);c.language="fr";c.allLessons=true;return c}
 private func wait(_ c:LessonLanguageController)async throws {for _ in 0..<1000{if !c.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Job did not finish")}

 /// Signed out: nothing is planned or requested, and the status says why.
 func testSignedOutStartsNothing()async throws {
  let translator=PlanTranslator(signedIn:false),c=try controller(translator);defer{c.shutdown()}
  let plan=await c.planAll(mode:"translate");XCTAssertNil(plan);XCTAssertFalse(c.busy)
  XCTAssertEqual(c.status,"Nothing was started: your sign-in could not be confirmed. Sign in to ChatGPT in Codex, then try again.")
  let translations=await translator.translations;XCTAssertEqual(translations,0)
 }
 /// Signed in: the plan counts the lessons still to translate, and has no time estimate before any earlier run.
 func testTranslatePlanCountsLessonsWithoutText()async throws {
  let translator=PlanTranslator(signedIn:true),c=try controller(translator);defer{c.shutdown()}
  let planned=await c.planAll(mode:"translate"),plan=try XCTUnwrap(planned);let total=c.library.lessons.count
  XCTAssertEqual(plan.lessons,total);XCTAssertEqual(plan.clips,0);XCTAssertNil(plan.seconds)
  XCTAssertEqual(plan.title,"Translate \(total) lessons into French?");XCTAssertTrue(plan.message.contains("No time estimate yet"),plan.message)
  let translations=await translator.translations;XCTAssertEqual(translations,0,"planning requests nothing");let checks=await translator.checks;XCTAssertEqual(checks,1)
  c.declinePlan();XCTAssertEqual(c.status,"Nothing was started.")
  c.allLessons=false;c.translate();try await wait(c);c.allLessons=true
  let again=await c.planAll(mode:"translate"),rest=try XCTUnwrap(again);XCTAssertEqual(rest.lessons,total-1,"a translated lesson is not planned again");XCTAssertNotNil(rest.seconds,"earlier runs give an estimate")
  XCTAssertTrue(rest.message.contains("Estimated time:"),rest.message)
 }
 /// Recording counts the clips still missing in translated lessons, and names the lessons skipped for lack of text.
 func testRecordPlanCountsMissingClips()async throws {
  let translator=PlanTranslator(signedIn:true),c=try controller(translator);defer{c.shutdown()}
  c.allLessons=false;c.translate();try await wait(c);c.allLessons=true
  let planned=await c.planAll(mode:"record"),plan=try XCTUnwrap(planned);let total=c.library.lessons.count
  XCTAssertEqual(plan.lessons,1);XCTAssertEqual(plan.clips,c.library.lessons[0].beats.count);XCTAssertEqual(plan.untranslated,total-1)
  XCTAssertEqual(plan.title,"Record \(plan.clips) clips for 1 lesson?");XCTAssertTrue(plan.message.contains("\(total-1) lessons have no translated text yet"),plan.message)
 }
 /// Nothing left to do: no confirmation, and the status says so.
 func testNothingToDoAsksNothing()async throws {
  let translator=PlanTranslator(signedIn:true),c=try controller(translator);defer{c.shutdown()}
  c.translate();try await wait(c)
  let plan=await c.planAll(mode:"translate");XCTAssertNil(plan);XCTAssertEqual(c.status,"Every lesson already has translated text in French.")
 }
}
