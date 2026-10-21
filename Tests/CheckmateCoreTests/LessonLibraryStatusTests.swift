import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateContent

private actor StatusTranslator:LessonTranslationProvider {
 var translations=0,checks=0
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {translations+=1;var text=source;text.title="Titre: "+source.title;return TranslationResult(text:text,model:"fixture",turnID:UUID().uuidString,tokens:UsageTokens(total:3))}
 func accountStatus()async throws->String {checks+=1;return "Fixture account"}
}
private actor StatusRecorder:LessonRecordingProvider {
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}
/// L-27: Settings lists every lesson with what is stored for the chosen language and voice (translated, recorded,
/// stale), and each row's Translate and Record go through the same sign-in check and confirmation as every lesson.
@MainActor final class LessonLibraryStatusTests:XCTestCase {
 private var directory:URL!
 override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent("lesson-status-"+UUID().uuidString)}
 override func tearDown(){try? FileManager.default.removeItem(at:directory)}
 private func controller(_ translator:StatusTranslator)throws -> LessonLanguageController {let c=try LessonLanguageController(library:CourseLibrary(),directory:directory,usage:UsageLedger(directory:directory.appendingPathComponent("Usage")),translator:translator,recorder:StatusRecorder());c.language="fr";return c}
 private func wait(_ c:LessonLanguageController)async throws {for _ in 0..<1000{if !c.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Job did not finish")}
 private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<500{if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail(what)}

 /// Text and recordings are counted per lesson; a stored file this version cannot use is stale, not missing.
 func testStatusCountsTextRecordingsAndStaleFiles()throws {
  let library=try CourseLibrary(),store=try LessonPackStore(directory:directory),first=LessonTranslation.source(library:library,index:0),second=LessonTranslation.source(library:library,index:1)
  XCTAssertEqual(store.status(source:first,locale:"fr",voice:"cedar"),LessonStoredStatus(translated:false,recorded:0,clips:first.beats.count,stale:false))
  try store.saveTranslation(first,source:first,locale:"fr");let beat=first.beats[0];_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak),transcript:beat.speak,beatID:beat.id,source:first,locale:"fr",voice:"cedar",model:"gpt-realtime")
  XCTAssertEqual(store.status(source:first,locale:"fr",voice:"cedar"),LessonStoredStatus(translated:true,recorded:1,clips:first.beats.count,stale:false))
  XCTAssertEqual(store.status(source:first,locale:"fr",voice:"marin").recorded,0,"recordings are counted for the chosen voice")
  let packs=directory.appendingPathComponent("LessonLanguages"),before=Set(try FileManager.default.contentsOfDirectory(atPath:packs.path))
  try store.saveTranslation(second,source:second,locale:"fr")
  let texts=try FileManager.default.contentsOfDirectory(atPath:packs.path).filter{!before.contains($0)}.map{packs.appendingPathComponent($0)};XCTAssertEqual(texts.count,1,"the second lesson's text is one new file")
  try Data("{\"version\":1,\"truncated".utf8).write(to:try XCTUnwrap(texts.first))
  XCTAssertEqual(store.status(source:second,locale:"fr",voice:"cedar"),LessonStoredStatus(translated:false,recorded:0,clips:second.beats.count,stale:true))
  XCTAssertEqual(LessonStoredStatus(translated:true,recorded:1,clips:4,stale:false).recordedText,"1 of 4")
  XCTAssertEqual(LessonStoredStatus(translated:true,recorded:4,clips:4,stale:false).recordedText,"All 4")
 }
 /// The controller publishes one status per lesson for the chosen language and refreshes it after a job.
 func testControllerPublishesEveryLessonsStatus()async throws {
  let c=try controller(StatusTranslator());defer{c.shutdown()}
  try await settle("statuses for every lesson"){c.lessonStatuses.count==c.library.lessons.count && c.lessonStatuses.allSatisfy{!$0.translated}}
  c.selectedLesson=2;c.translate();try await wait(c)
  try await settle("lesson 3 shows its text"){c.lessonStatuses.count==c.library.lessons.count && c.lessonStatuses[2].translated}
  XCTAssertEqual(c.lessonStatuses.indices.filter{c.lessonStatuses[$0].translated},[2])
 }
 /// A row's Translate selects that lesson, checks the sign-in and counts its work before anything is requested.
 func testOneLessonPlanSelectsItAndConfirmsFirst()async throws {
  let translator=StatusTranslator(),c=try controller(translator);defer{c.shutdown()}
  c.allLessons=true
  let planned=await c.plan(mode:"translate",lesson:3),plan=try XCTUnwrap(planned)
  XCTAssertFalse(c.allLessons);XCTAssertEqual(c.selectedLesson,3);XCTAssertEqual(plan.lessons,1);XCTAssertEqual(plan.title,"Translate 1 lesson into French?")
  let requested=await translator.translations,checks=await translator.checks;XCTAssertEqual(requested,0,"planning requests nothing");XCTAssertEqual(checks,1)
  let record=await c.plan(mode:"record",lesson:3);XCTAssertNil(record);XCTAssertEqual(c.status,"This lesson has no translated text yet; translate it first.")
  c.translate();try await wait(c)
  let again=await c.plan(mode:"translate",lesson:3);XCTAssertNil(again);XCTAssertEqual(c.status,"This lesson already has translated text in French.")
  let recording=await c.plan(mode:"record",lesson:3),clips=try XCTUnwrap(recording);XCTAssertEqual(clips.clips,c.library.lessons[3].beats.count);XCTAssertEqual(clips.lessons,1)
 }
 /// L-26: the lesson picker groups lessons by their course section, in course order, covering every lesson once.
 func testLessonGroupsFollowTheCourseSections()throws {
  let library=try CourseLibrary(),groups=LessonLanguageController.groups(library)
  XCTAssertEqual(groups.map(\.title),library.sections.map{$0.title});XCTAssertEqual(groups.flatMap(\.lessons),Array(library.lessons.indices))
  XCTAssertTrue(groups.count>1,"the course has more than one section")
 }
}
