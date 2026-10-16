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
import SaidGuard


/// Translates every lesson unchanged except for a marked title.
private actor FixTranslator:LessonTranslationProvider {
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {var text=source;text.title="Titre: "+source.title;return TranslationResult(text:text,model:"fake",turnID:UUID().uuidString,tokens:UsageTokens(total:3))}
 func accountStatus()async throws->String {"Fake account"}
}
/// Records clips in call order; scripts in `failing` fail, and the `holding` script waits until the job is cancelled.
private actor FixRecorder:LessonRecordingProvider {
 var failing:Set<String>,holding:String?,scripts:[String]=[];init(failing:Set<String>=[],holding:String?=nil){self.failing=failing;self.holding=holding}
 func settle(){failing=[];holding=nil}
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {
  scripts.append(script);if failing.contains(script){throw CheckmateError.invalid("The recording did not match the requested script.")}
  if script==holding{try await Task.sleep(for:.seconds(30))}
  return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")
 }
}

/// Audit findings #12 (grouped numbers in transcripts), #13 (purge and unreadable manifests), #14 (damaged recordings
/// named as damaged text) and #15 (cancelling forgets this run's failures).
@MainActor final class LessonLanguageFixTests:XCTestCase {
 private var dir:URL!
 override func setUp(){dir=FileManager.default.temporaryDirectory.appendingPathComponent("lesson-language-fix-"+UUID().uuidString)}
 override func tearDown(){try? FileManager.default.removeItem(at:dir)}
 private func wait(_ controller:LessonLanguageController)async throws {for _ in 0..<1500{if !controller.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Job did not finish")}
 private func controller(_ recorder:any LessonRecordingProvider)throws -> LessonLanguageController {let c=try LessonLanguageController(library:try CourseLibrary(),directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:FixTranslator(),recorder:recorder);c.language="fr";return c}
 /// The stored files whose content decodes as a lesson pack manifest.
 private func manifests()throws -> [URL] {let packs=dir.appendingPathComponent("LessonLanguages");return try FileManager.default.contentsOfDirectory(at:packs,includingPropertiesForKeys:nil).filter{(try? JSONDecoder().decode(LessonPack.self,from:Data(contentsOf:$0))) != nil}}
 private func audioCount()throws -> Int {try FileManager.default.contentsOfDirectory(at:dir.appendingPathComponent("LessonLanguages"),includingPropertiesForKeys:nil).filter{(try? FileHandle(forReadingFrom:$0).read(upToCount:4))==Data("RIFF".utf8)}.count}

 /// #12: an English number matches its grouped, plain and spelled forms. In another language the said guard reads a
 /// number as written or in the locale's words, never through its grouping: "1.000" against "1000" is a regeneration
 /// (the model reads its own script back as written), never a false acceptance of another number.
 func testGroupedNumbersMatchTheirPlainAndSpelledForms(){
  XCTAssertTrue(saidMatches("The board has 1,000 positions.","The board has 1000 positions.",language:"en"))
  XCTAssertTrue(saidMatches("The board has one thousand positions.","The board has 1,000 positions.",language:"en"))
  XCTAssertTrue(saidMatches("Das Brett hat eintausend Stellungen.","Das Brett hat 1000 Stellungen.",language:"de"),"the locale's own spelling")
  XCTAssertFalse(saidMatches("Das Brett hat tausend Stellungen.","Das Brett hat 1000 Stellungen.",language:"de"),"a shortened spelling is a regeneration")
  XCTAssertFalse(saidMatches("Das Brett hat 1.000 Stellungen.","Das Brett hat 1000 Stellungen.",language:"de"))
  XCTAssertFalse(saidMatches("Il y a 1\u{202F}000 positions.","Il y a 1000 positions.",language:"fr"))
  XCTAssertFalse(saidMatches("1,00,000","100000",language:"hi"))
  XCTAssertFalse(saidMatches("The board has 1,000 positions.","The board has 1001 positions.",language:"en"))
  XCTAssertFalse(saidMatches("squares 1,2,3","squares 123",language:"en"),"A list is not a grouped number")
  XCTAssertFalse(saidMatches("1.000","1000",language:"en"),"In English a point is a decimal separator, not grouping")
 }

 /// #13: a current manifest that cannot be decoded (damaged, or written by a newer version) keeps its recordings:
 /// purge removes no audio it cannot attribute. (A manifest that cannot even be opened already fails the purge.)
 func testPurgeKeepsAudioOfAnUndecodableCurrentManifest()throws {
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),store=try LessonPackStore(directory:dir)
  try store.saveTranslation(source,source:source,locale:"fr");for beat in source.beats.prefix(2){_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak),transcript:beat.speak,beatID:beat.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")}
  let manifest=try XCTUnwrap(try manifests().first),original=try Data(contentsOf:manifest);XCTAssertEqual(try audioCount(),2)
  try Data("{\"version\":1,\"truncated".utf8).write(to:manifest)
  XCTAssertEqual(try store.purgeOutdated(library:library).files,0,"Audio of a manifest that cannot be inspected is not orphaned")
  XCTAssertEqual(try audioCount(),2);try original.write(to:manifest)
  let pack=try XCTUnwrap(try store.partialPack(source:source,locale:"fr",voice:"cedar"));for beat in source.beats.prefix(2){XCTAssertNotNil(try store.clipURL(pack:pack,beatID:beat.id))}
 }
 /// #13, same class at launch: a manifest this version cannot decode (damaged, or written by a newer version) keeps its audio.
 func testLaunchSweepKeepsAudioOfAnUndecodableManifest()throws {
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),store=try LessonPackStore(directory:dir)
  try store.saveTranslation(source,source:source,locale:"fr");let beat=source.beats[0];_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak),transcript:beat.speak,beatID:beat.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")
  let manifest=try XCTUnwrap(try manifests().first),original=try Data(contentsOf:manifest);try Data("{\"version\":2,\"future\":true}".utf8).write(to:manifest)
  try store.sweepStale(library:library);XCTAssertEqual(try store.purgeOutdated(library:library).files,0);XCTAssertEqual(try audioCount(),1)
  try original.write(to:manifest);XCTAssertNotNil(try store.clipURL(pack:try XCTUnwrap(try store.partialPack(source:source,locale:"fr",voice:"cedar")),beatID:beat.id))
  try FileManager.default.removeItem(at:manifest);try store.sweepStale(library:library);XCTAssertEqual(try audioCount(),0,"Audio no manifest names is still swept")
 }

 /// #14: damaged recordings with intact text show the text and point at removing the recordings, not discarding the text.
 func testDamagedRecordingsWithIntactTextRecommendRemovingRecordings()async throws {
  let c=try controller(FixRecorder());c.translate();try await wait(c);c.record();try await wait(c)
  let manifest=try XCTUnwrap(try manifests().first);try Data("damaged".utf8).write(to:manifest)
  c.selectedLesson=1;c.selectedLesson=0;for _ in 0..<300 where c.storedStatus=="Checking stored lesson data…"{try await Task.sleep(for:.milliseconds(10))}
  XCTAssertFalse(c.inspection.isEmpty,"The intact translated text is still shown")
  XCTAssertFalse(c.storedStatus.contains("Discard translated text"),c.storedStatus);XCTAssertTrue(c.storedStatus.contains("Remove stored lesson"),c.storedStatus)
 }

 /// #15: a clip that failed before the job was cancelled is retried after the clips still to record on Resume.
 func testFailuresBeforeACancelAreRetriedLastOnResume()async throws {
  let setup=try controller(FixRecorder());setup.translate();try await wait(setup)
  let text=try XCTUnwrap(try setup.store.translation(source:LessonTranslation.source(library:setup.library,index:0),locale:"fr"));XCTAssertGreaterThan(text.beats.count,2)
  let recorder=FixRecorder(failing:[text.beats[0].speak],holding:text.beats[1].speak),c=try controller(recorder)
  c.record();for _ in 0..<300 {if await recorder.scripts.count>=2{break};try await Task.sleep(for:.milliseconds(10))}
  c.cancel();try await wait(c);XCTAssertTrue(c.status.hasPrefix("Cancelled"),c.status)
  let before=await recorder.scripts.count;XCTAssertEqual(before,2);await recorder.settle()
  c.record();try await wait(c)
  let resumed=Array(await recorder.scripts.dropFirst(before));XCTAssertEqual(resumed.count,text.beats.count)
  XCTAssertEqual(resumed.last,text.beats[0].speak,"The clip that failed before the cancel is retried last");XCTAssertEqual(resumed.first,text.beats[1].speak)
 }
}
