import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// Translates every lesson, recording the order lessons were attempted.
private actor AuditTranslator:LessonTranslationProvider {
 var order:[String]=[]
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {order.append(source.lessonID);var text=source;text.title="Titre: "+source.title;return TranslationResult(text:text,model:"fake",turnID:UUID().uuidString,tokens:UsageTokens(total:3))}
 func accountStatus()async throws->String {"Fake account"}
}
/// Records every clip except the scripts listed in `failing`, in call order.
private actor AuditRecorder:LessonRecordingProvider {
 let failing:Set<String>;var scripts:[String]=[];init(failing:Set<String>){self.failing=failing}
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {scripts.append(script);if failing.contains(script){throw CheckmateError.invalid("The recording did not match the requested script.")};return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}

/// Audit findings #12 and #14 (lesson jobs) and #13 (cumulative usage counters).
@MainActor final class LessonJobAuditTests:XCTestCase {
 private var dir:URL!
 override func setUp(){dir=FileManager.default.temporaryDirectory.appendingPathComponent("lesson-job-audit-"+UUID().uuidString)}
 override func tearDown(){try? FileManager.default.removeItem(at:dir)}
 private func wait(_ controller:LessonLanguageController)async throws {for _ in 0..<1500{if !controller.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Job did not finish")}
 private func controller(_ library:CourseLibrary,_ translator:any LessonTranslationProvider,_ recorder:any LessonRecordingProvider)throws -> LessonLanguageController {let c=try LessonLanguageController(library:library,directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:translator,recorder:recorder);c.language="fr";return c}

 /// #12: clips that keep failing in the first lesson are retried only after every other selected lesson's fresh clips,
 /// so three persistent failures cannot stop every Resume before later lessons are reached.
 func testPersistentClipFailuresInOneLessonDoNotBlockLaterLessons()async throws {
  let library=try CourseLibrary(),translator=AuditTranslator()
  let setup=try controller(library,translator,AuditRecorder(failing:[]));for index in [0,1]{setup.selectedLesson=index;setup.translate();try await wait(setup)}
  let first=try XCTUnwrap(try setup.store.translation(source:LessonTranslation.source(library:library,index:0),locale:"fr")),second=try XCTUnwrap(try setup.store.translation(source:LessonTranslation.source(library:library,index:1),locale:"fr"))
  XCTAssertGreaterThan(first.beats.count,3);let failing=Set(first.beats.prefix(3).map(\.speak));XCTAssertEqual(failing.count,3)
  let recorder=AuditRecorder(failing:failing),c=try controller(library,translator,recorder)
  c.record();try await wait(c);XCTAssertTrue(c.status.hasPrefix("Stopped after three failures in a row"),c.status)
  let before=await recorder.scripts.count;XCTAssertEqual(before,3,"Precondition: the first lesson's first three clips failed")
  c.allLessons=true;c.record();try await wait(c)
  let resumed=Array(await recorder.scripts.dropFirst(before))
  XCTAssertTrue(second.beats.allSatisfy{resumed.contains($0.speak)},"Every clip of the second lesson is recorded on Resume")
  let firstRetry=resumed.firstIndex{failing.contains($0)} ?? resumed.count,lastFresh=resumed.lastIndex{!failing.contains($0)} ?? -1
  XCTAssertLessThan(lastFresh,firstRetry,"Last run's failed clips are retried only after every fresh clip")
 }

 /// #14: cleanup is a job of its own: busy while it runs, no translation starts meanwhile, and its result is reported.
 func testPurgingIsABusyJobThatBlocksOtherJobs()async throws {
  let library=try CourseLibrary(),translator=AuditTranslator(),c=try controller(library,translator,AuditRecorder(failing:[]))
  c.purgeOutdated();XCTAssertTrue(c.busy,"Cleanup marks the controller busy")
  c.translate();try await wait(c)
  let calls=await translator.order.count;XCTAssertEqual(calls,0,"No translation starts while cleanup runs")
  XCTAssertEqual(c.status,"No outdated translations or recordings to remove.")
  c.translate();try await wait(c);let after=await translator.order.count;XCTAssertEqual(after,1,"After cleanup a job starts normally")
 }

 /// #13: a cumulative snapshot that carries only some counters keeps the others already known.
 func testPartialCumulativeSnapshotKeepsKnownCounters() {
  let ledger=UsageLedger(directory:dir.appendingPathComponent("Usage")),id=ledger.begin(activity:.translation,provider:"codex",sessionID:"a")
  ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(input:20,output:8,total:28,reasoning:4),status:.running,cumulative:true)
  ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(total:30),status:.completed,cumulative:true)
  let tokens=ledger.records.first?.tokens;XCTAssertEqual(tokens,UsageTokens(input:20,output:8,total:30,reasoning:4))
  let totals=ledger.totals();XCTAssertEqual(totals.input,20);XCTAssertEqual(totals.output,8);XCTAssertEqual(totals.total,30)
 }
}
