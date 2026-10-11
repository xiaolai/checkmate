import XCTest
@testable import CheckmateCore
private actor FakeTranslator:LessonTranslationProvider {
 var calls=0
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {calls+=1;var text=source;text.title="French title: "+source.title;text.teaches=source.teaches.map{"French goal: "+$0};text.beats=source.beats.map{var beat=$0;beat.stepTitle="French step: "+beat.stepTitle;beat.say="French subtitle: "+beat.say;beat.speak="French speech: "+beat.speak;return beat};onUsage("turn","fake",UsageTokens(total:5));return TranslationResult(text:text,model:"fake",turnID:"turn",tokens:UsageTokens(total:5))}
 func accountStatus()async throws->String {"Fake account"}
}
private actor FakeRecorder:LessonRecordingProvider {
 var calls=0
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {calls+=1;onUsage(UUID().uuidString,UsageTokens(total:7));return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:UsageTokens(total:7),model:"gpt-realtime")}
}
@MainActor final class LessonPipelineTests:XCTestCase {
 func wait(_ controller:LessonLanguageController)async throws {for _ in 0..<1000{if !controller.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Job did not finish")}
 func testPipelineResumeAndVoiceInvalidatesOnlyAudio()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let translator=FakeTranslator(),recorder=FakeRecorder(),library=try CourseLibrary(),usage=UsageLedger(directory:dir.appendingPathComponent("Usage")),controller=try LessonLanguageController(library:library,directory:dir,usage:usage,translator:translator,recorder:recorder)
  controller.language="fr";controller.translate();try await wait(controller);XCTAssertFalse(controller.inspection.isEmpty)
  controller.preview();try await wait(controller);XCTAssertNotNil(controller.previewURL)
  controller.record();try await wait(controller)
  let source=LessonTranslation.source(library:library,index:0)
  let pack=try XCTUnwrap(controller.store.completePack(source:source,locale:"fr",voice:"cedar"));XCTAssertEqual(pack.clips.count,source.beats.count)
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);session.state.settings.lessonLanguage="fr";player.packs=controller.store
  for _ in 0..<100 {if player.fallbackMessage==nil{break};try await Task.sleep(for:.milliseconds(10))}
  XCTAssertNil(player.fallbackMessage);XCTAssertEqual(player.subtitle,pack.translation.beats[0].say);XCTAssertNotEqual(player.subtitle,source.beats[0].say);XCTAssertEqual(player.localizedTitle(index:0),pack.translation.title);XCTAssertEqual(player.localizedStepTitle(index:0,step:0),pack.translation.beats[0].stepTitle);XCTAssertEqual(player.teaches,pack.translation.teaches);player.play();player.advance(by:player.duration);player.shutdown()
  controller.record();try await wait(controller);let calls=await recorder.calls;XCTAssertEqual(calls,source.beats.count)
  controller.voice="marin";XCTAssertNil(controller.previewURL);XCTAssertNil(try controller.store.completePack(source:source,locale:"fr",voice:"marin"));controller.translate();try await wait(controller);let textCalls=await translator.calls;XCTAssertEqual(textCalls,1)
  XCTAssertTrue(usage.records.allSatisfy{$0.status == .completed});XCTAssertFalse(String(decoding:try usage.exportJSON(),as:UTF8.self).contains(source.beats[0].say))
 }

 func testCanonicalFingerprintAndWAVHeader()throws {let library=try CourseLibrary();let a=LessonTranslation.source(library:library,index:0);for _ in 0..<20 {XCTAssertEqual(a.fingerprint,LessonTranslation.source(library:library,index:0).fingerprint)};let wav=LessonRecording.wav(Data(repeating:0,count:480));XCTAssertTrue(LessonRecording.validWAV(wav));var bad=wav;bad[22]=2;XCTAssertFalse(LessonRecording.validWAV(bad))}
}
private actor SlowRecorder:LessonRecordingProvider {
 var calls=0
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {calls+=1;try await Task.sleep(for:.seconds(5));return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}
extension LessonPipelineTests {
 func testCancelAndAllCourseTranslation()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let translator=FakeTranslator(),recorder=SlowRecorder(),library=try CourseLibrary(),usage=UsageLedger(directory:dir.appendingPathComponent("Usage")),controller=try LessonLanguageController(library:library,directory:dir,usage:usage,translator:translator,recorder:recorder)
  controller.language="fr";controller.allLessons=true;controller.translate();try await wait(controller);let translations=await translator.calls;XCTAssertEqual(translations,library.lessons.count)
  controller.allLessons=false;controller.record();for _ in 0..<100 {if await recorder.calls>0{break};try await Task.sleep(for:.milliseconds(10))};controller.cancel();try await wait(controller);XCTAssertTrue(controller.status.contains("Cancelled"));XCTAssertNil(try controller.store.completePack(source:LessonTranslation.source(library:library,index:0),locale:"fr",voice:"cedar"));XCTAssertEqual(usage.records.last?.status,.cancelled)
 }

}
private actor CompletingTranslator:LessonTranslationProvider {
 var pending:CheckedContinuation<TranslationResult,Never>?,source:LessonTranslation?,calls=0
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {calls+=1;self.source=source;return await withCheckedContinuation{pending=$0}}
 func finish(){guard let source else{return};pending?.resume(returning:TranslationResult(text:source,model:"fake",turnID:"completed",tokens:UsageTokens(total:9)));pending=nil}
 func accountStatus()async throws->String{"Fake"}
}
extension LessonPipelineTests {
 func testCancelAfterProviderCompletionKeepsPaidTranslation()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let translator=CompletingTranslator(),library=try CourseLibrary(),ledger=UsageLedger(directory:dir.appendingPathComponent("Usage")),controller=try LessonLanguageController(library:library,directory:dir,usage:ledger,translator:translator,recorder:FakeRecorder());controller.language="fr";controller.translate();for _ in 0..<100{if await translator.calls>0{break};try await Task.sleep(for:.milliseconds(10))};controller.cancel();await translator.finish();try await wait(controller);XCTAssertNotNil(try controller.store.translation(source:LessonTranslation.source(library:library,index:0),locale:"fr"));XCTAssertEqual(ledger.records.last?.tokens?.total,9);controller.translate();try await wait(controller);let calls=await translator.calls;XCTAssertEqual(calls,1)
 }
 func testUnchangedPackRefreshKeepsCurrentPlayback()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),store=try LessonPackStore(directory:dir);try store.saveTranslation(source,source:source,locale:"fr");for beat in source.beats{_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak,seconds:1),transcript:beat.speak,beatID:beat.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")};let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);session.state.settings.lessonLanguage="fr";player.packs=store;for _ in 0..<100{if !player.localizationLoading{break};try await Task.sleep(for:.milliseconds(10))};player.openLesson(index:0);player.play();player.advance(by:0.25);player.reloadLocalizedPacks();XCTAssertTrue(player.playing);for _ in 0..<20{try await Task.sleep(for:.milliseconds(10))};XCTAssertTrue(player.playing);XCTAssertGreaterThanOrEqual(player.seconds,0.25);player.shutdown()
 }
}

/// Fails the clip whose script matches `failing`, recording every call in order.
private actor SelectiveRecorder:LessonRecordingProvider {
 let failing:String;var scripts:[String]=[];init(failing:String){self.failing=failing}
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {scripts.append(script);if script==failing{throw CheckmateError.invalid("The recording did not match the requested script.")};return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}
private actor FailingTranslator:LessonTranslationProvider {
 var calls=0
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {calls+=1;throw CheckmateError.invalid("The translation did not keep the chess notation.")}
 func accountStatus()async throws->String {"Fake account"}
}
extension LessonPipelineTests {
 /// One bad clip is named, the rest of the lesson is still recorded, and Resume retries the bad clip last.
 func testAFailingClipIsNamedTheJobContinuesAndResumeRetriesItLast()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0)
  let translator=FakeTranslator(),usage=UsageLedger(directory:dir.appendingPathComponent("Usage"))
  let setup=try LessonLanguageController(library:library,directory:dir,usage:usage,translator:translator,recorder:FakeRecorder());setup.language="fr";setup.translate();try await wait(setup)
  let text=try XCTUnwrap(try setup.store.translation(source:source,locale:"fr")),bad=text.beats[1].speak,recorder=SelectiveRecorder(failing:bad)
  let controller=try LessonLanguageController(library:library,directory:dir,usage:usage,translator:translator,recorder:recorder);controller.language="fr"
  controller.record();try await wait(controller)
  XCTAssertEqual(controller.problems.count,1);XCTAssertTrue(controller.problems[0].hasPrefix("Lesson 1 “"),controller.problems[0]);XCTAssertTrue(controller.problems[0].contains("clip 2"),controller.problems[0])
  let first=await recorder.scripts;XCTAssertEqual(first.count,text.beats.count,"Every other clip was still recorded")
  controller.record();try await wait(controller)
  let second=await recorder.scripts;XCTAssertEqual(Array(second.dropFirst(first.count)),[bad],"Only the failed clip is retried; verified clips are reused")
 }
 /// A cause that fails everything (here, every translation) stops after three in a row instead of paying for forty.
 func testThreeFailuresInARowStopTheJob()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let translator=FailingTranslator(),library=try CourseLibrary()
  let controller=try LessonLanguageController(library:library,directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:translator,recorder:FakeRecorder())
  controller.language="fr";controller.allLessons=true;controller.translate();try await wait(controller)
  let calls=await translator.calls;XCTAssertEqual(calls,3);XCTAssertEqual(controller.problems.count,3);XCTAssertTrue(controller.status.hasPrefix("Stopped after three failures in a row"),controller.status)
 }
}
extension LessonPipelineTests {
 /// A damaged stored translation can be discarded for that one lesson, without discarding the whole language.
 func testADamagedTranslationCanBeDiscardedForOneLesson()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0)
  let controller=try LessonLanguageController(library:library,directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:FakeTranslator(),recorder:FakeRecorder())
  controller.language="fr";controller.translate();try await wait(controller)
  let packs=dir.appendingPathComponent("LessonLanguages")
  for name in try FileManager.default.contentsOfDirectory(atPath:packs.path){try Data("damaged".utf8).write(to:packs.appendingPathComponent(name))}
  XCTAssertThrowsError(try controller.store.translation(source:source,locale:"fr"));XCTAssertTrue(controller.store.hasStoredText(source:source,locale:"fr"))
  controller.selectedLesson=1;controller.selectedLesson=0;for _ in 0..<100 where !controller.inspection.isEmpty{try await Task.sleep(for:.milliseconds(10))}
  XCTAssertTrue(controller.canDiscardTranslation,"A damaged file is still discardable");controller.discardTranslation()
  XCTAssertFalse(controller.store.hasStoredText(source:source,locale:"fr"));XCTAssertNil(try controller.store.translation(source:source,locale:"fr"))
 }
}
extension LessonPipelineTests {
 /// Text made for an earlier version of a lesson can be removed; the current translation is kept.
 func testPurgeRemovesOnlyOutdatedTranslations()throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let library=try CourseLibrary(),current=LessonTranslation.source(library:library,index:0),store=try LessonPackStore(directory:dir)
  var older=current;older.title=current.title+" (earlier wording)";XCTAssertNotEqual(older.fingerprint,current.fingerprint)
  var text=current;text.title="Titre";try store.saveTranslation(text,source:current,locale:"fr")
  var old=older;old.title="Ancien titre";try store.saveTranslation(old,source:older,locale:"fr")
  XCTAssertEqual(try store.purgeOutdated(library:library).files,1)
  XCTAssertTrue(store.hasStoredText(source:current,locale:"fr"));XCTAssertFalse(store.hasStoredText(source:older,locale:"fr"))
  XCTAssertEqual(try store.purgeOutdated(library:library).files,0)
 }
}
