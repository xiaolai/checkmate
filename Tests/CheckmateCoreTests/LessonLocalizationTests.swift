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

final class LessonLocalizationTests:XCTestCase {
 func testExactIDsAndCoordinates() throws {
  let library=try CourseLibrary(), source=LessonTranslation.source(library:library,index:0)
  XCTAssertNoThrow(try source.validate(against:source))
  var invalid=source;invalid.beats.removeLast()
  XCTAssertThrowsError(try invalid.validate(against:source))
  invalid=source;invalid.beats[0].id="invented"
  XCTAssertThrowsError(try invalid.validate(against:source))
 }
 func testCompletePackOnlyAndVoiceReuse() throws {
  let library=try CourseLibrary(),dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=try LessonPackStore(directory:URL(fileURLWithPath:dir.path,isDirectory:true)),source=LessonTranslation.source(library:library,index:0)
  try store.saveTranslation(source,source:source,locale:"fr")
  XCTAssertEqual(try store.translation(source:source,locale:"fr"),source)
  XCTAssertNil(try store.completePack(source:source,locale:"fr",voice:"cedar"))
  XCTAssertNil(try store.completePack(source:source,locale:"fr",voice:"marin"))
 }
 func testPCMValidation() throws {
  XCTAssertThrowsError(try LessonRecording.validate(pcm:Data(),transcript:"hi",script:"hi",language:"en"))
  XCTAssertThrowsError(try LessonRecording.validate(pcm:Data([1]),transcript:"hi",script:"hi",language:"en"))
  XCTAssertThrowsError(try LessonRecording.validate(pcm:Data(repeating:0,count:480),transcript:"wrong",script:"hi",language:"en"))
  XCTAssertEqual(try LessonRecording.validate(pcm:plausibleLessonPCM("hi",seconds:1),transcript:"Hi!",script:"hi",language:"en"),1)
  XCTAssertThrowsError(try LessonRecording.validate(pcm:Data(repeating:0,count:48000),transcript:"Hi!",script:"hi",language:"en"),"A silent clip is rejected")
  // The lesson's own language decides how its numbers may be read: French spells 3 as "trois", English does not.
  XCTAssertEqual(try LessonRecording.validate(pcm:plausibleLessonPCM("Le cavalier va en f3.",seconds:2),transcript:"Le cavalier va en f trois.",script:"Le cavalier va en f3.",language:"fr"),2)
  XCTAssertThrowsError(try LessonRecording.validate(pcm:plausibleLessonPCM("The knight goes to f3.",seconds:2),transcript:"The knight goes to f trois.",script:"The knight goes to f3.",language:"en"))
 }
}
extension LessonLocalizationTests {
 func testCoordinatesExtraFieldsAndMechanicsFingerprint()throws {
  let library=try CourseLibrary();var source=LessonTranslation.source(library:library,index:0);source.beats[0].say += " e4 O-O Nf3";var changed=source;changed.beats[0].say=changed.beats[0].say.replacingOccurrences(of:"e4",with:"d4");XCTAssertThrowsError(try changed.validate(against:source))
  var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as! [String:Any];object["moves"]=[["e2","e4"]];XCTAssertThrowsError(try LessonTranslation.decode(JSONSerialization.data(withJSONObject:object)))
  var course=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("course.json"))) as! [String:Any];var lessons=course["lessons"] as! [[String:Any]],beats=lessons[0]["beats"] as! [[String:Any]];beats[0]["pause"]=99;lessons[0]["beats"]=beats;course["lessons"]=lessons;let edited=try JSONDecoder().decode(CourseLibrary.self,from:JSONSerialization.data(withJSONObject:course));let before=LessonTranslation.source(library:library,index:0),after=LessonTranslation.source(library:edited,index:0);XCTAssertEqual(before,after);XCTAssertNotEqual(before.fingerprint,after.fingerprint)
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let store=try LessonPackStore(directory:dir);try store.saveTranslation(before,source:before,locale:"fr");XCTAssertNil(try store.translation(source:after,locale:"fr"))
  var narrationOnly=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("course.json"))) as! [String:Any];var voices=narrationOnly["voices"] as! [[[String:Any]]];voices[0][0]["seconds"]=99;voices[0][0]["duration"]=100;narrationOnly["voices"]=voices;let regenerated=try JSONDecoder().decode(CourseLibrary.self,from:JSONSerialization.data(withJSONObject:narrationOnly));XCTAssertEqual(before.fingerprint,LessonTranslation.source(library:regenerated,index:0).fingerprint)
 }
 func testCorruptAudioProfileDuplicateManifestAndRemoval()throws {
  let source=LessonTranslation.source(library:try CourseLibrary(),index:0),dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let store=try LessonPackStore(directory:dir);try store.saveTranslation(source,source:source,locale:"fr")
  var pack=try store.saveClip(pcm:plausibleLessonPCM(source.beats[0].speak),transcript:source.beats[0].speak,beatID:source.beats[0].id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")
  let url=try XCTUnwrap(store.clipURL(pack:pack,beatID:source.beats[0].id));var wav=try Data(contentsOf:url);wav[22]=2;try wav.write(to:url,options:.atomic);XCTAssertNil(try store.clipURL(pack:pack,beatID:source.beats[0].id))
  let manifest=store.directory.appendingPathComponent(LessonTranslation.hash(Data("pack|\(source.fingerprint)|fr|cedar|1".utf8)))
  pack.clips.append(pack.clips[0]);try JSONEncoder().encode(pack).write(to:manifest,options:.atomic);XCTAssertThrowsError(try store.partialPack(source:source,locale:"fr",voice:"cedar"));pack.clips.removeLast();pack.clips[0].generation=99;try JSONEncoder().encode(pack).write(to:manifest,options:.atomic);XCTAssertNil(try store.clipURL(pack:pack,beatID:source.beats[0].id))
  XCTAssertNil(try store.partialPack(source:source,locale:"fr",voice:"marin"));try store.remove(source:source,locale:"fr",voice:"cedar");XCTAssertEqual(try store.translation(source:source,locale:"fr"),source);XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
 }
 func testSymlinksAndOversizeTranslationRejected()throws {
  let source=LessonTranslation.source(library:try CourseLibrary(),index:0),dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let store=try LessonPackStore(directory:dir);try store.saveTranslation(source,source:source,locale:"fr")
  let text=store.directory.appendingPathComponent(LessonTranslation.hash(Data("text|\(source.fingerprint)|fr".utf8))),outside=dir.appendingPathComponent("outside.json");try JSONEncoder().encode(source).write(to:outside);try FileManager.default.removeItem(at:text);try FileManager.default.createSymbolicLink(at:text,withDestinationURL:outside);XCTAssertThrowsError(try store.translation(source:source,locale:"fr"));try FileManager.default.removeItem(at:text);try Data(repeating:32,count:2_000_001).write(to:text);XCTAssertThrowsError(try store.translation(source:source,locale:"fr"))
  let alias=dir.appendingPathComponent("alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:dir);XCTAssertThrowsError(try LessonPackStore(directory:alias))
 }
}
extension LessonLocalizationTests {
 func testDiscardAllVoicesAndSweepStaleSources()throws {
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let store=try LessonPackStore(directory:dir);try store.saveTranslation(source,source:source,locale:"fr")
  let first=source.beats[0];for voice in ["cedar","marin"]{_ = try store.saveClip(pcm:plausibleLessonPCM(first.speak),transcript:first.speak,beatID:first.id,source:source,locale:"fr",voice:voice,model:"gpt-realtime-2026-10-01")}
  XCTAssertThrowsError(try store.saveClip(pcm:plausibleLessonPCM(first.speak),transcript:first.speak,beatID:first.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime-mini"))
  try store.discardTranslation(source:source,locale:"fr");XCTAssertNil(try store.translation(source:source,locale:"fr"));XCTAssertNil(try store.partialPack(source:source,locale:"fr",voice:"cedar"));XCTAssertNil(try store.partialPack(source:source,locale:"fr",voice:"marin"))
  try store.saveTranslation(source,source:source,locale:"fr");let pack=try store.saveClip(pcm:plausibleLessonPCM(first.speak),transcript:first.speak,beatID:first.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime");let audio=try XCTUnwrap(store.clipURL(pack:pack,beatID:first.id))
  let orphan=store.directory.appendingPathComponent(String(repeating:"a",count:64));try Data(contentsOf:audio).write(to:orphan);var course=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("course.json"))) as! [String:Any];var lessons=course["lessons"] as! [[String:Any]];lessons[0]["title"]="Changed source title";course["lessons"]=lessons;let updated=try JSONDecoder().decode(CourseLibrary.self,from:JSONSerialization.data(withJSONObject:course));try store.sweepStale(library:updated);XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path));XCTAssertTrue(FileManager.default.fileExists(atPath:audio.path));XCTAssertEqual(try store.translation(source:source,locale:"fr"),source);XCTAssertNil(try store.translation(source:LessonTranslation.source(library:updated,index:0),locale:"fr"))
 }
}
