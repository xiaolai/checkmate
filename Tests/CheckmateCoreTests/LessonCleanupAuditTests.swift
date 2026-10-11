import XCTest
@testable import CheckmateCore

private actor CleanupTranslator:LessonTranslationProvider {
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {TranslationResult(text:source,model:"fake",turnID:UUID().uuidString,tokens:UsageTokens(total:3))}
 func accountStatus()async throws->String {"Fake account"}
}
private actor CleanupRecorder:LessonRecordingProvider {
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}

/// Audit findings #12 (manifests and checkpoints that decode but this version does not support keep their paid data)
/// and #13 (cleanup cannot be cancelled, so Cancel neither claims to cancel it nor is offered).
@MainActor final class LessonCleanupAuditTests:XCTestCase {
 private var dir:URL!
 override func setUp(){dir=FileManager.default.temporaryDirectory.appendingPathComponent("lesson-cleanup-audit-"+UUID().uuidString)}
 override func tearDown(){try? FileManager.default.removeItem(at:dir)}
 private var packs:URL {dir.appendingPathComponent("LessonLanguages")}
 private func stored()throws -> [URL] {try FileManager.default.contentsOfDirectory(at:packs,includingPropertiesForKeys:nil)}
 private func manifest()throws -> URL {try XCTUnwrap(try stored().first{(try? JSONDecoder().decode(LessonPack.self,from:Data(contentsOf:$0))) != nil})}
 private func audioCount()throws -> Int {try stored().filter{(try? FileHandle(forReadingFrom:$0).read(upToCount:4))==Data("RIFF".utf8)}.count}
 /// Rewrites a stored JSON file with some fields changed, as a newer version of the app might have written it.
 private func rewrite(_ file:URL,_ change:(inout [String:Any])->Void)throws -> Data {var root=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]);change(&root);let data=try JSONSerialization.data(withJSONObject:root);try data.write(to:file);return data}
 private func recordedStore(beats:Int)throws -> (CourseLibrary,LessonTranslation,LessonPackStore) {
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),store=try LessonPackStore(directory:dir)
  try store.saveTranslation(source,source:source,locale:"fr");for beat in source.beats.prefix(beats){_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak),transcript:beat.speak,beatID:beat.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")}
  return (library,source,store)
 }

 /// #12: the launch sweep keeps the recordings of a manifest that decodes but has a version this app does not support.
 func testLaunchSweepKeepsAudioOfAnUnsupportedManifestVersion()throws {
  let (library,_,store)=try recordedStore(beats:2);_ = try rewrite(try manifest()){$0["version"]=2};XCTAssertEqual(try audioCount(),2)
  try store.sweepStale(library:library);XCTAssertEqual(try audioCount(),2,"A newer manifest's recordings are not orphaned")
 }
 /// #12: the launch sweep also keeps recordings while a decodable manifest has an unknown voice or does not sit at its own name.
 func testLaunchSweepKeepsAudioOfAnUnrecognisedManifest()throws {
  let (library,_,store)=try recordedStore(beats:1);let file=try manifest()
  let original=try rewrite(file){$0["voice"]="alloy"};try store.sweepStale(library:library);XCTAssertEqual(try audioCount(),1,"Unknown voice")
  try FileManager.default.removeItem(at:file);try original.write(to:packs.appendingPathComponent(String(repeating:"b",count:64)));try store.sweepStale(library:library);XCTAssertEqual(try audioCount(),1,"Manifest stored under another name")
 }
 /// #12, same class in Remove outdated translations: a newer manifest under its own (unknown) name keeps itself and its audio.
 func testPurgeKeepsAnUnsupportedManifestAndItsAudio()throws {
  let (library,_,store)=try recordedStore(beats:2);let file=try manifest(),moved=packs.appendingPathComponent(String(repeating:"c",count:64))
  _ = try rewrite(file){$0["version"]=2};try FileManager.default.moveItem(at:file,to:moved)
  XCTAssertEqual(try store.purgeOutdated(library:library).files,0);XCTAssertEqual(try audioCount(),2);XCTAssertTrue(FileManager.default.fileExists(atPath:moved.path))
 }
 /// #12, same class for translated text: an outdated-looking checkpoint of an unsupported version is not purged.
 func testPurgeKeepsATextCheckpointOfAnUnsupportedVersion()throws {
  let (_,source,store)=try recordedStore(beats:0);let text=try XCTUnwrap(try stored().first);_ = try rewrite(text){$0["version"]=2}
  var course=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("course.json"))) as? [String:Any]);var lessons=try XCTUnwrap(course["lessons"] as? [[String:Any]]);lessons[0]["title"]="Changed source title";course["lessons"]=lessons
  let updated=try JSONDecoder().decode(CourseLibrary.self,from:JSONSerialization.data(withJSONObject:course));XCTAssertNotEqual(LessonTranslation.source(library:updated,index:0).fingerprint,source.fingerprint)
  XCTAssertEqual(try store.purgeOutdated(library:updated).files,0);XCTAssertTrue(FileManager.default.fileExists(atPath:text.path))
 }

 /// #13: cleanup runs to completion; Cancel is not offered for it and does not report a cancellation that never happens.
 func testCleanupIsNotCancellable()async throws {
  let c=try LessonLanguageController(library:try CourseLibrary(),directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:CleanupTranslator(),recorder:CleanupRecorder());c.language="fr"
  c.purgeOutdated();XCTAssertTrue(c.busy);XCTAssertFalse(c.canCancel,"Cancel is not offered during cleanup")
  c.cancel();XCTAssertEqual(c.status,"Removing outdated translations…","Cancel does not claim to stop cleanup")
  for _ in 0..<1500 where c.busy{try await Task.sleep(for:.milliseconds(10))};XCTAssertFalse(c.busy)
  XCTAssertEqual(c.status,"No outdated translations or recordings to remove.")
  c.translate();XCTAssertTrue(c.canCancel,"Other jobs remain cancellable");c.cancel();for _ in 0..<1500 where c.busy{try await Task.sleep(for:.milliseconds(10))}
 }
}
