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

@testable import CheckmateNative
import SaidGuard

/// Translates every lesson except those listed in `failing`, recording the order lessons were attempted.
private actor GapOrderTranslator:LessonTranslationProvider {
 var failing:Set<String>,order:[String]=[];init(failing:Set<String>=[]){self.failing=failing}
 func fail(_ ids:Set<String>){failing=ids}
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {order.append(source.lessonID);if failing.contains(source.lessonID){throw CheckmateError.invalid("The translation did not keep the chess notation.")};var text=source;text.title="Titre: "+source.title;return TranslationResult(text:text,model:"fake",turnID:UUID().uuidString,tokens:UsageTokens(total:3))}
 func accountStatus()async throws->String {"Fake account"}
}
/// Records every clip except the scripts listed in `failing` (or every clip when `failAll`), in call order.
private actor GapOrderRecorder:LessonRecordingProvider {
 var failing:Set<String>,failAll:Bool,scripts:[String]=[];init(failing:Set<String>=[],failAll:Bool=false){self.failing=failing;self.failAll=failAll}
 func fail(_ value:Set<String>){failing=value}
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {scripts.append(script);if failAll || failing.contains(script){throw CheckmateError.invalid("The recording did not match the requested script.")};return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}

@MainActor final class GapRecoveryJobTests:XCTestCase {
 private var dir:URL!
 override func setUp(){dir=FileManager.default.temporaryDirectory.appendingPathComponent("gap-recovery-"+UUID().uuidString)}
 override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_LESSON_FIXTURE");try? FileManager.default.removeItem(at:dir)}
 private func wait(_ controller:LessonLanguageController)async throws {for _ in 0..<1500{if !controller.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Job did not finish")}
 private func controller(_ library:CourseLibrary,_ translator:any LessonTranslationProvider,_ recorder:any LessonRecordingProvider=GapOrderRecorder())throws -> LessonLanguageController {let c=try LessonLanguageController(library:library,directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:translator,recorder:recorder);c.language="fr";return c}

 // MARK: Persistence (PL2-2, PL-2/SH-8)

 /// PL2-2: when saving fails, Export writes the in-memory state, not the (unreadable) last saved file.
 func testExportStateWritesInMemoryStateWhenSaveFails()throws {
  let store=StateStore(directory:dir);try FileManager.default.createDirectory(at:store.url,withIntermediateDirectories:true)  // a directory where the state file belongs: every save fails
  var state=ApplicationState();state.settings.volume=0.3;state.settings.boardTheme="blue";state.puzzles["extra-1"]=PuzzleProgress()
  XCTAssertThrowsError(try store.save(state),"Precondition: the save must fail")
  let destination=dir.appendingPathComponent("exported.json"),fileExport=dir.appendingPathComponent("file-export.json")
  XCTAssertThrowsError(try store.export(to:fileExport),"Copying the saved file cannot work here; only exporting the state itself can")
  try store.exportState(state,to:destination)
  let exported=try JSONDecoder().decode(ApplicationState.self,from:Data(contentsOf:destination))
  XCTAssertEqual(exported.settings.volume,0.3);XCTAssertEqual(exported.settings.boardTheme,"blue");XCTAssertNotNil(exported.puzzles["extra-1"]);try StateStore.validate(exported)
  let reloaded=try StateStore(directory:dir.appendingPathComponent("reimport")).loadAfterWriting(Data(contentsOf:destination));XCTAssertEqual(reloaded.settings.volume,0.3,"The export is a loadable saved state")
 }
 /// PL-2/SH-8: Start Fresh moves the unreadable file aside byte-for-byte; a fresh state can then load and save without touching it.
 func testUnreadableStateIsSetAsideNotDeletedOrOverwritten()throws {
  let store=StateStore(directory:dir);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  let damaged=Data("{\"schemaVersion\":1,\"truncated".utf8);try damaged.write(to:store.url)
  XCTAssertThrowsError(try store.load(),"Precondition: the state is unreadable")
  let kept=try store.setAsideUnreadableState()
  XCTAssertEqual(kept.deletingLastPathComponent().standardizedFileURL,dir.standardizedFileURL);XCTAssertTrue(kept.lastPathComponent.hasPrefix("state-unreadable-"));XCTAssertNotEqual(kept.lastPathComponent,store.url.lastPathComponent)
  XCTAssertEqual(try Data(contentsOf:kept),damaged,"The unreadable file is kept exactly as it was")
  XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:kept.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
  XCTAssertFalse(FileManager.default.fileExists(atPath:store.url.path));let opened=try store.load();XCTAssertEqual(opened.settings,AppSettings(),"Start Fresh opens a new state");XCTAssertTrue(opened.puzzles.isEmpty);XCTAssertTrue(opened.practice.pgn.isEmpty)
  var fresh=ApplicationState();fresh.settings.volume=0.2;try store.save(fresh);try store.save(fresh)
  XCTAssertEqual(try Data(contentsOf:kept),damaged,"Saving the fresh state never overwrites the set-aside file")
  // A second failure keeps both files: set-aside never reuses a name.
  try damaged.write(to:store.url);let second=try store.setAsideUnreadableState()
  XCTAssertNotEqual(second,kept);XCTAssertEqual(try Data(contentsOf:kept),damaged);XCTAssertEqual(try Data(contentsOf:second),damaged)
 }
 /// Start Fresh end to end: the app model cannot open over the damaged file, and opens after it is set aside.
 func testNativeModelStartsFreshAfterSettingAsideUnreadableState()throws {
  setenv("CHECKMATE_DATA_DIR",dir.path,1);let store=StateStore(directory:dir);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  let damaged=Data("not json".utf8);try damaged.write(to:store.url)
  XCTAssertThrowsError(try NativeModel(),"Precondition: launch fails on the unreadable file")
  let kept=try store.setAsideUnreadableState()
  let model=try NativeModel();defer{model.shutdown()};XCTAssertEqual(model.session.state.settings,AppSettings())
  XCTAssertEqual(try Data(contentsOf:kept),damaged)
 }

 // MARK: Quit guards (TX-6)

 /// Quitting during a paid lesson job asks first, and honours both answers; with no job running it never asks.
 func testQuitDuringLessonJobAsksAndOtherwiseDoesNot()async throws {
  setenv("CHECKMATE_DATA_DIR",dir.path,1);setenv("CHECKMATE_LESSON_FIXTURE","1",1)  // fixture translator: no provider contacted
  let model=try NativeModel();defer{model.shutdown()}
  var asked=0;model.confirmQuitDuringLessonJob={asked+=1;return false}
  XCTAssertFalse(model.lessonLanguages.busy);XCTAssertTrue(model.mayQuitDuringLessonJob());XCTAssertEqual(asked,0,"No job running: quitting does not ask")
  model.lessonLanguages.language="fr";model.lessonLanguages.translate();XCTAssertTrue(model.lessonLanguages.busy,"Precondition: a lesson job is running")
  XCTAssertFalse(model.mayQuitDuringLessonJob(),"Keep Working keeps the app open");XCTAssertEqual(asked,1)
  model.confirmQuitDuringLessonJob={asked+=1;return true};XCTAssertTrue(model.mayQuitDuringLessonJob(),"Quit Anyway quits");XCTAssertEqual(asked,2)
  model.lessonLanguages.cancel();try await wait(model.lessonLanguages)
  model.confirmQuitDuringLessonJob={XCTFail("The job has ended; nothing to confirm");return false};XCTAssertTrue(model.mayQuitDuringLessonJob())
 }
 /// Quitting writes the current in-memory state immediately rather than relying on the debounced save.
 func testQuitAfterSavingWritesCurrentState()throws {
  setenv("CHECKMATE_DATA_DIR",dir.path,1)
  let model=try NativeModel();defer{model.shutdown()}
  model.session.state.settings.volume=0.35;model.session.state.settings.boardTheme="green"
  XCTAssertTrue(model.mayQuitAfterSaving())
  let saved=try StateStore(directory:dir).load();XCTAssertEqual(saved.settings.volume,0.35);XCTAssertEqual(saved.settings.boardTheme,"green")
 }

 // MARK: Paid lesson jobs (LE2-1, LE-1, LE-4)

 /// LE2-1: a lesson that fails to translate is named by number and title, with the cause.
 func testTranslationProblemNamesTheLesson()async throws {
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:1)
  let c=try controller(library,GapOrderTranslator(failing:[source.lessonID]));c.selectedLesson=1;c.translate();try await wait(c)
  XCTAssertEqual(c.problems,["Lesson 2 “\(source.title)”: The translation did not keep the chess notation."])
  XCTAssertTrue(c.status.hasPrefix("Finished with 1 problem;"),c.status)
 }
 /// LE-4: a lesson that failed last run is attempted after every other lesson on Resume, not first.
 func testLessonThatFailedLastRunIsRetriedLast()async throws {
  let library=try CourseLibrary();XCTAssertGreaterThan(library.lessons.count,3)
  let failed=library.lessons[1].id,translator=GapOrderTranslator(failing:[failed]),c=try controller(library,translator)
  c.selectedLesson=1;c.translate();try await wait(c);XCTAssertEqual(c.problems.count,1)
  await translator.fail([]);c.allLessons=true;c.translate();try await wait(c)
  let order=Array(await translator.order.dropFirst());XCTAssertEqual(order.count,library.lessons.count)
  XCTAssertEqual(order.last,failed,"Last run's failure is retried last");XCTAssertEqual(order.first,library.lessons[0].id);XCTAssertTrue(c.problems.isEmpty)
 }
 /// LE-4: within a lesson, a clip that failed last run is recorded after clips that still need recording.
 func testClipThatFailedLastRunIsRecordedLast()async throws {
  let library=try CourseLibrary(),translator=GapOrderTranslator()
  let setup=try controller(library,translator);setup.translate();try await wait(setup)
  let text=try XCTUnwrap(try setup.store.translation(source:LessonTranslation.source(library:library,index:0),locale:"fr"));XCTAssertGreaterThan(text.beats.count,2)
  let recorder=GapOrderRecorder(failing:[text.beats[0].speak]),c=try controller(library,translator,recorder)
  c.record();try await wait(c);XCTAssertEqual(c.problems.count,1);XCTAssertTrue(c.problems[0].contains("clip 1"),c.problems[0])
  let first=await recorder.scripts.count;await recorder.fail([]);c.removeClip(step:2)
  c.record();try await wait(c)
  let second=Array(await recorder.scripts.dropFirst(first));XCTAssertEqual(second,[text.beats[2].speak,text.beats[0].speak],"The fresh clip first, last run's failure last");XCTAssertTrue(c.problems.isEmpty)
 }
 /// LE-1: three clip failures in a row stop a recording job: no fourth clip is billed, and each failure names its clip.
 func testThreeClipFailuresInARowStopRecording()async throws {
  let library=try CourseLibrary(),translator=GapOrderTranslator()
  let setup=try controller(library,translator);setup.translate();try await wait(setup)
  let source=LessonTranslation.source(library:library,index:0);XCTAssertGreaterThan(source.beats.count,3)
  let recorder=GapOrderRecorder(failAll:true),usage=UsageLedger(directory:dir.appendingPathComponent("Usage")),c=try LessonLanguageController(library:library,directory:dir,usage:usage,translator:translator,recorder:recorder);c.language="fr"
  c.record();try await wait(c)
  let calls=await recorder.scripts.count;XCTAssertEqual(calls,3,"No fourth clip is billed")
  XCTAssertEqual(usage.records.filter{$0.activity == .lessonRecording}.count,3)
  XCTAssertEqual(c.problems.map{$0.components(separatedBy:":").first!},(1...3).map{"Lesson 1 “\(source.title)”, clip \($0)"})
  XCTAssertTrue(c.status.hasPrefix("Stopped after three failures in a row"),c.status)
 }
 /// LE-1: failures that are not consecutive never stop the job; a success in between resets the count.
 func testNonConsecutiveFailuresDoNotStopTheJob()async throws {
  let library=try CourseLibrary();XCTAssertGreaterThan(library.lessons.count,5)
  let ids=Set([0,1,3,4].map{library.lessons[$0].id}),translator=GapOrderTranslator(failing:ids),c=try controller(library,translator)
  c.allLessons=true;c.translate();try await wait(c)
  let calls=await translator.order.count;XCTAssertEqual(calls,library.lessons.count,"Every lesson was attempted");XCTAssertEqual(c.problems.count,4)
  XCTAssertTrue(c.status.hasPrefix("Finished with 4 problems"),c.status)
 }

 // MARK: Transcript matching

 /// A recording transcript matches its script however a number is written; a different number or word never does.
 func testTranscriptMatchingToleratesHowNumbersAreWritten()throws {
  XCTAssertTrue(saidMatches("Move the knight 3 squares.","Move the knight three squares.",language:"en"))
  XCTAssertTrue(saidMatches("Move the knight three squares.","Move the knight 3 squares.",language:"en"))
  XCTAssertTrue(saidMatches("There are twenty one pieces","There are 21 pieces",language:"en"),"Hyphen and space in a spelled number are both accepted")
  XCTAssertTrue(saidMatches("There are twenty-one pieces","There are 21 pieces",language:"en"))
  XCTAssertTrue(saidMatches("KNIGHT, to f3!","knight to f three",language:"en"))
  XCTAssertTrue(saidMatches("ｅ３","e three",language:"en"),"Full-width digits count as ASCII")
  XCTAssertTrue(saidMatches("Le cavalier va en f trois.","Le cavalier va en f3.",language:"fr"))
  XCTAssertFalse(saidMatches("Move the knight 4 squares.","Move the knight three squares.",language:"en"))
  XCTAssertFalse(saidMatches("knight to f thirty three","knight to f3",language:"en"))
  XCTAssertFalse(saidMatches("Move the knight squares.","Move the knight 3 squares.",language:"en"),"A missing number fails")
  XCTAssertFalse(saidMatches("Now move the knight 3 squares.","Move the knight 3 squares.",language:"en"),"An added word fails")
 }

 // MARK: Legacy import (PL2-3)

 /// A legacy archive (values wrapper, settings as a JSON string, as the web export writes them) merges its settings
 /// over the current ones: the settings it carries win, every other setting the learner has survives.
 func testLegacyImportMergesSettingsOverCurrentOnes()throws {
  var state=ApplicationState();state.settings.voiceAutoConnect=false;state.settings.voiceMicrophone=false;state.settings.voiceInputDevice="USB Desk Mic";state.settings.companionAutoStart=false;state.settings.companionRole="opponent";state.settings.coachVoice="marin";state.settings.lessonLanguage="de";state.settings.coachReasoningEffort="high";state.settings.voiceVolume=0.6
  let archive:[String:Any]=["values":["checkmate-settings-v1":#"{"voiceLanguage":"ja","volume":0.3,"coachingMode":"quiet","voiceMicrophone":true}"#]]
  let report=try LegacyImporter.apply(JSONSerialization.data(withJSONObject:archive),to:&state,course:CourseLibrary())
  XCTAssertEqual(state.settings.voiceLanguage,"ja");XCTAssertEqual(state.settings.volume,0.3);XCTAssertEqual(state.settings.coachingMode,"quiet");XCTAssertTrue(state.settings.voiceMicrophone,"A setting the archive carries is imported")
  XCTAssertFalse(state.settings.voiceAutoConnect,"Voice auto-connect is not re-enabled");XCTAssertEqual(state.settings.voiceInputDevice,"USB Desk Mic","The microphone choice survives")
  XCTAssertFalse(state.settings.companionAutoStart,"MCP auto-start is not re-enabled");XCTAssertEqual(state.settings.companionRole,"opponent")
  XCTAssertEqual(state.settings.coachVoice,"marin");XCTAssertEqual(state.settings.lessonLanguage,"de");XCTAssertEqual(state.settings.coachReasoningEffort,"high");XCTAssertEqual(state.settings.voiceVolume,0.6)
  XCTAssertEqual(Set(report.recovered),["Setting: coachingMode","Setting: voiceLanguage","Setting: voiceMicrophone","Setting: volume"],"Only the carried settings are reported")
 }
}

private extension StateStore {
 /// Writes `data` as this store's state file and loads it the way launch does.
 func loadAfterWriting(_ data:Data)throws -> ApplicationState {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try data.write(to:url);return try load()}
}
