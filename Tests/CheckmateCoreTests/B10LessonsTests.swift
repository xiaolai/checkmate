import XCTest
@testable import CheckmateCore

/// Records which narration a lesson asked for, without any audio.
@MainActor private final class B10NarrationSpy:NarrationService {
 var bundled=0,local=0,volumes:[Double]=[],failure:String?
 var narrationFailure:String? {failure}
 func play(file:String,seconds:Double,settings:AppSettings){bundled+=1}
 func play(localURL:URL,seconds:Double,settings:AppSettings){local+=1}
 func pause(){}
 func stop(){}
 func setNarrationVolume(_ volume:Double){volumes.append(volume)}
}
private actor B10Translator:LessonTranslationProvider {
 var calls=0
 func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {calls+=1;return TranslationResult(text:b10Translated(source),model:"fake",turnID:"turn",tokens:nil)}
 func accountStatus()async throws->String {"Fake account"}
}
/// Records every script; while `held`, each recording waits for `release()`.
private actor B10Recorder:LessonRecordingProvider {
 var scripts:[String]=[];private var held:Bool;private var gate:CheckedContinuation<Void,Never>?
 init(held:Bool=false){self.held=held}
 func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {scripts.append(script);if held{await withCheckedContinuation{gate=$0}};return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
 func release(){held=false;gate?.resume();gate=nil}
}
private func b10Translated(_ source:LessonTranslation)->LessonTranslation {var text=source;text.beats=source.beats.map{var beat=$0;beat.say="FR "+beat.say;beat.speak="FR "+beat.speak;return beat};return text}
private func b10Directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}

@MainActor final class B10LessonsPlaybackTests:XCTestCase {
 /// LE-6: Remove deletes recordings before the background rescan ends; the open lesson must drop to English at once.
 func testRemovedRecordingsFallBackToEnglishBeforeTheRescanEnds()async throws {
  let dir=b10Directory();defer{try? FileManager.default.removeItem(at:dir)}
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),text=b10Translated(source),store=try LessonPackStore(directory:dir)
  try store.saveTranslation(text,source:source,locale:"fr")
  for beat in text.beats{_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak),transcript:beat.speak,beatID:beat.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")}
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session),spy=B10NarrationSpy();player.audio=spy
  session.state.settings.lessonLanguage="fr";player.packs=store
  for _ in 0..<300 where player.localizationLoading{try await Task.sleep(for:.milliseconds(10))}
  player.openLesson(index:0);XCTAssertEqual(player.subtitle,text.beats[0].say);XCTAssertNil(player.fallbackMessage)
  try store.remove(source:source,locale:"fr",voice:"cedar");player.reloadLocalizedPacks()  // as Remove's onPacksChanged does
  XCTAssertEqual(player.subtitle,source.beats[0].say,"The removed translation is not shown while the rescan runs")
  XCTAssertNotNil(player.fallbackMessage);XCTAssertFalse(player.localizationLoading)
  player.play();XCTAssertEqual(spy.local,0,"Play never reaches a deleted recording");XCTAssertEqual(spy.bundled,1)
  player.shutdown()
 }
 /// LE-6: a same-selection rescan started during a language change keeps Play gated until a scan completes.
 func testSameSelectionRescanKeepsAPendingLanguageChangeLoading()async throws {
  let dir=b10Directory();defer{try? FileManager.default.removeItem(at:dir)}
  let store=try LessonPackStore(directory:dir),session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
  session.state.settings.lessonLanguage="fr";player.packs=store;XCTAssertTrue(player.localizationLoading)
  player.reloadLocalizedPacks();XCTAssertTrue(player.localizationLoading,"A nested rescan must not end the language change's loading")
  XCTAssertEqual(player.fallbackMessage?.hasPrefix("Checking"),true,"Loading is not reported as an incomplete recording")
  for _ in 0..<300 where player.localizationLoading{try await Task.sleep(for:.milliseconds(10))}
  XCTAssertFalse(player.localizationLoading);XCTAssertEqual(player.fallbackMessage?.contains("English"),true)
  player.shutdown()
 }
 /// LE2-2: a narration that cannot play is shown in the lesson instead of a silent timeline.
 func testNarrationFailureIsShownInTheLesson()throws {
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session),spy=B10NarrationSpy();player.audio=spy
  player.openLesson(index:0);player.play();XCTAssertEqual(player.feedback,"");player.pause()
  spy.failure=NativeAudio.playbackFailure;player.play();XCTAssertEqual(player.feedback,NativeAudio.playbackFailure)
  player.shutdown()
 }
 /// LE2-3: a volume drag adjusts the playing clip; only switching narration or (un)muting restarts it.
 func testVolumeChangesAdjustNarrationWithoutRestartingIt()throws {
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session),spy=B10NarrationSpy();player.audio=spy
  player.settingsChanged()  // settle the initial pack selection
  player.openLesson(index:0);player.play();XCTAssertEqual(spy.bundled,1)
  for volume in [0.9,0.6,0.3]{session.state.settings.volume=volume;player.settingsChanged()}
  XCTAssertEqual(spy.bundled,1,"A volume drag does not restart narration");XCTAssertEqual(spy.volumes,[0.9,0.6,0.3])
  session.state.settings.effectsVolume=0.2;player.settingsChanged();XCTAssertEqual(spy.bundled,1)
  session.state.settings.narration=false;player.settingsChanged();XCTAssertEqual(spy.bundled,2)
  session.state.settings.narration=true;player.settingsChanged();XCTAssertEqual(spy.bundled,3)
  session.state.settings.volume=0;player.settingsChanged();XCTAssertEqual(spy.bundled,4)
  session.state.settings.volume=0.5;player.settingsChanged();XCTAssertEqual(spy.bundled,5)
  player.shutdown()
 }
 /// Same class as LE2-3: unrelated settings changes must not keep restarting a mini-game reply.
 func testUnrelatedSettingChangesDoNotRestartAMiniGameReply()async throws {
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
  session.state.settings.pieceDuration=0;player.settingsChanged()
  player.openLesson(index:3);player.startPawnDuel();player.click("g2");player.click("g4");XCTAssertTrue(player.miniThinking)
  for tick in 0..<40 where player.miniGame?.history.count != 2 {session.state.settings.volume=tick.isMultiple(of:2) ? 0.4:0.6;player.settingsChanged();try await Task.sleep(for:.milliseconds(50))}
  XCTAssertEqual(player.miniGame?.history.count,2,"The computer replied while the volume kept changing");XCTAssertEqual(player.miniTurn,"w")
  player.shutdown()
 }
 /// LE-13: an unknown saved lesson opens the first lesson at its start, not at another lesson's transcript step.
 func testUnknownSavedLessonOpensTheFirstLessonAtItsStart()throws {
  var state=ApplicationState();state.course.lessonID="retired-lesson";state.course.step=5;state.course.segmentID="retired-lesson:5"
  let player=try LearningPlayer(session:GameSession(engine:nil,state:state))
  XCTAssertEqual(player.lessonIndex,0);XCTAssertEqual(player.step,0);player.shutdown()
 }
 /// IR-12: when the app bundle on disk is replaced or moved while running, the narration failure asks for a relaunch.
 func testReplacedOrMovedAppAsksForARelaunch()throws {
  let dir=b10Directory();defer{try? FileManager.default.removeItem(at:dir)}
  let app=dir.appendingPathComponent("Checkmate.app"),plist=app.appendingPathComponent("Contents/Info.plist")
  try FileManager.default.createDirectory(at:plist.deletingLastPathComponent(),withIntermediateDirectories:true)
  func install(_ version:String)throws {try Data("<plist version=\"1.0\"><dict><key>CFBundleVersion</key><string>\(version)</string></dict></plist>".utf8).write(to:plist,options:.atomic)}
  try install("1");let audio=NativeAudio(automation:true,scores:[:],bundleURL:app)
  XCTAssertEqual(audio.bundledNarrationFailure,NativeAudio.playbackFailure)
  try install("2");XCTAssertEqual(audio.bundledNarrationFailure,NativeAudio.replacedFailure)
  let moved=NativeAudio(automation:true,scores:[:],bundleURL:app);try FileManager.default.moveItem(at:app,to:dir.appendingPathComponent("Elsewhere.app"))
  XCTAssertEqual(moved.bundledNarrationFailure,NativeAudio.replacedFailure)
  XCTAssertEqual(NativeAudio(automation:true,scores:[:],bundleURL:dir).bundledNarrationFailure,NativeAudio.playbackFailure,"Outside an app bundle nothing is reported as replaced")
 }
 /// LE-11: the Settings preview gate and the narration player decide audibility the same way.
 func testPreviewGateMatchesNarrationPolicy(){
  for (narration,volume,audible) in [(true,1.0,true),(true,0.0,false),(false,1.0,false),(false,0.0,false)] {
   var settings=AppSettings();settings.narration=narration;settings.volume=volume
   XCTAssertEqual(AudioPolicy.narrationAudible(settings),audible);XCTAssertEqual(AudioPolicy(automation:false).mayPlay(enabled:settings.narration,volume:settings.volume),audible)
  }
 }
}

@MainActor final class B10LessonsReviewTests:XCTestCase {
 /// TX-4: a mini-game reply in flight when a review opens never plays behind it; returning resumes it.
 func testNoMiniGameReplyBehindAReview()async throws {
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
  session.state.settings.pieceDuration=0;player.settingsChanged()
  player.openLesson(index:3);player.startPawnDuel();player.click("g2");player.click("g4");XCTAssertTrue(player.miniThinking)
  session.suspendForReview();let shown=session.lesson?.pieces
  for _ in 0..<30 where player.miniThinking{try await Task.sleep(for:.milliseconds(50))}
  XCTAssertFalse(player.miniThinking);XCTAssertEqual(player.miniGame?.history.count,1,"No computer move behind the review");XCTAssertEqual(session.lesson?.pieces,shown)
  session.state.settings.miniOpponentProfile="beginner";player.settingsChanged();XCTAssertFalse(player.miniThinking,"A settings change queues nothing behind the review")
  try await Task.sleep(for:.milliseconds(600));XCTAssertEqual(player.miniGame?.history.count,1)
  session.returnFromReview();player.resumeMiniOpponent();XCTAssertTrue(player.miniThinking)
  for _ in 0..<40 where player.miniGame?.history.count != 2{try await Task.sleep(for:.milliseconds(50))}
  XCTAssertEqual(player.miniGame?.history.count,2);XCTAssertEqual(player.miniTurn,"w");XCTAssertEqual(session.lesson?.turn,"w")
  player.shutdown()
 }
 /// TX-4: lesson state changed during a review is published on return, not behind the review.
 func testLessonStateIsPublishedAfterTheReviewNotBehindIt()throws {
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
  player.openLesson(index:0);let before=session.lesson?.step;XCTAssertEqual(before,player.step)
  session.suspendForReview();player.seek(step:2);XCTAssertEqual(session.lesson?.step,before,"Nothing is published behind the review")
  session.returnFromReview();player.resumeMiniOpponent();XCTAssertEqual(session.lesson?.step,2)
  player.shutdown()
 }
}

@MainActor final class B10LessonsJobTests:XCTestCase {
 private func settle(_ controller:LessonLanguageController)async throws {for _ in 0..<1000{if !controller.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Job did not finish")}
 /// LE-8: Settings changing the language mid-job never shows the job's preview under the new language.
 func testLanguageChangeDuringAJobNeverShowsItsPreviewUnderTheNewLanguage()async throws {
  let dir=b10Directory();defer{try? FileManager.default.removeItem(at:dir)}
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),recorder=B10Recorder(held:true)
  let controller=try LessonLanguageController(library:library,directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:B10Translator(),recorder:recorder)
  controller.language="fr";controller.translate();try await settle(controller)
  controller.preview();for _ in 0..<300{if await recorder.scripts.count>0{break};try await Task.sleep(for:.milliseconds(10))}
  controller.language="de";await recorder.release();try await settle(controller)
  XCTAssertNil(controller.previewURL,"A French preview is never offered under German");XCTAssertTrue(controller.status.contains("changed while it ran"),controller.status)
  XCTAssertEqual(try controller.store.partialPack(source:source,locale:"fr",voice:"cedar")?.clips.count,1,"The paid clip is kept for French")
  controller.language="fr";controller.preview();try await settle(controller)
  XCTAssertNotNil(controller.previewURL);let calls=await recorder.scripts.count;XCTAssertEqual(calls,1,"Selecting French again reuses the kept clip")
  // LE2-2 (preview): a preview that could not play reports it; one that played leaves the status alone.
  let ready=controller.status;controller.reportPreviewPlayback(failure:nil);XCTAssertEqual(controller.status,ready)
  controller.reportPreviewPlayback(failure:NativeAudio.playbackFailure);XCTAssertEqual(controller.status,NativeAudio.playbackFailure)
 }
 /// LE2-8: one bad clip is removed and re-recorded alone, not the whole lesson.
 func testRemovingOneClipReRecordsOnlyThatClip()async throws {
  let dir=b10Directory();defer{try? FileManager.default.removeItem(at:dir)}
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:0),recorder=B10Recorder()
  let controller=try LessonLanguageController(library:library,directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:B10Translator(),recorder:recorder)
  controller.language="fr";controller.translate();try await settle(controller);controller.record();try await settle(controller)
  let text=try XCTUnwrap(try controller.store.translation(source:source,locale:"fr")),recorded=await recorder.scripts.count
  XCTAssertEqual(recorded,source.beats.count);XCTAssertNotNil(try controller.store.completePack(source:source,locale:"fr",voice:"cedar"))
  controller.removeClip(step:2);XCTAssertTrue(controller.status.hasPrefix("Clip 3 removed"),controller.status)
  XCTAssertNil(try controller.store.completePack(source:source,locale:"fr",voice:"cedar"));XCTAssertEqual(try controller.store.partialPack(source:source,locale:"fr",voice:"cedar")?.clips.count,source.beats.count-1)
  controller.removeClip(step:2);XCTAssertTrue(controller.status.contains("no stored recording"),controller.status)
  controller.record();try await settle(controller)
  let scripts=await recorder.scripts;XCTAssertEqual(Array(scripts.dropFirst(recorded)),[text.beats[2].speak],"Only the removed clip is recorded again")
  XCTAssertNotNil(try controller.store.completePack(source:source,locale:"fr",voice:"cedar"))
 }
 /// LE2-7: paid jobs run only for a canonical, recognized language, whichever path supplied it.
 func testPaidJobsRefuseUnrecognizedOrNonCanonicalLanguages()async throws {
  let dir=b10Directory();defer{try? FileManager.default.removeItem(at:dir)}
  let translator=B10Translator(),controller=try LessonLanguageController(library:try CourseLibrary(),directory:dir,usage:UsageLedger(directory:dir.appendingPathComponent("Usage")),translator:translator,recorder:B10Recorder())
  for language in ["fr-XX","fr-999","zh-hans","qq"] {controller.language=language;controller.translate();XCTAssertFalse(controller.busy,language);XCTAssertEqual(controller.status,"Choose a supported language and lesson first.",language)}
  let calls=await translator.calls;XCTAssertEqual(calls,0)
  XCTAssertEqual(LessonLanguages.normalizedSelection("es-419"),"es-419");XCTAssertNil(LessonLanguages.normalizedSelection("fr-999"))
  for code in LessonLanguages.supported {XCTAssertEqual(LessonLanguages.normalizedSelection(code),code,"Built-in language \(code) must pass the paid-job check")}
  let source=LessonTranslation.source(library:try CourseLibrary(),index:0)
  let client=CodexSubscriptionClient(executable:dir.appendingPathComponent("missing-codex"),credentialURL:dir.appendingPathComponent("missing-auth.json"),automationAllowed:true,timeout:1)
  do{_=try await client.translate(source:source,locale:"fr-XX",onUsage:{_,_,_ in});XCTFail("Translated an unrecognized language")}catch{XCTAssertEqual(String(describing:error),"Choose a valid language identifier.")}
  let recorder=RealtimeLessonRecorder(timeout:1,secretProvider:{throw CheckmateError.unavailable("no secret")},socketFactory:{_ in throw CheckmateError.unavailable("no socket")})
  do{_=try await recorder.record(script:"Bonjour.",locale:"fr-XX",voice:"cedar",onUsage:{_,_ in});XCTFail("Recorded an unrecognized language")}catch{XCTAssertEqual(String(describing:error),"Invalid recording language or voice.")}
 }
}

final class B10LessonsStoreTests:XCTestCase {
 /// LE-7: a rescan re-hashes only recordings written since they were verified; a replaced file is verified again.
 func testRescansReuseVerifiedRecordings()throws {
  let dir=b10Directory();defer{try? FileManager.default.removeItem(at:dir)}
  let source=LessonTranslation.source(library:try CourseLibrary(),index:0),store=try LessonPackStore(directory:dir)
  try store.saveTranslation(source,source:source,locale:"fr")
  for beat in source.beats{_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak),transcript:beat.speak,beatID:beat.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")}
  XCTAssertNotNil(try store.validatedPack(source:source,locale:"fr",voice:"cedar"));XCTAssertEqual(store.audioVerifications,source.beats.count)
  let result=try XCTUnwrap(try store.validatedPack(source:source,locale:"fr",voice:"cedar"));XCTAssertEqual(store.audioVerifications,source.beats.count,"Unchanged recordings are not hashed again")
  let replaced=try XCTUnwrap(result.1[source.beats[0].id]);var altered=try Data(contentsOf:replaced);altered[altered.count-1]^=0xFF;try altered.write(to:replaced,options:.atomic)  // same size, different bytes: only the hash can tell
  XCTAssertNil(try store.validatedPack(source:source,locale:"fr",voice:"cedar"),"A replaced recording is verified again and rejected");XCTAssertEqual(store.audioVerifications,source.beats.count+1)
 }
 /// LE-9: provider limit names cannot carry bidi overrides, zero-width or other invisible characters.
 func testAccountLimitNamesKeepOnlyVisibleCharacters(){
  XCTAssertEqual(CodexSubscriptionClient.safeLabel("codex\u{202E}evil\u{200B}"),"codexevil")
  XCTAssertEqual(CodexSubscriptionClient.safeLabel("\u{2066}a\u{200D}b\u{FEFF}c\u{2069}"),"abc")
  XCTAssertEqual(CodexSubscriptionClient.safeLabel("line\nbreak"),"linebreak")
  XCTAssertEqual(CodexSubscriptionClient.safeLabel("cafe\u{0301}"),"café")
  XCTAssertEqual(CodexSubscriptionClient.safeLabel("codex_primary-2"),"codex_primary-2")
  XCTAssertEqual(CodexSubscriptionClient.safeLabel("\u{202E}\u{200B}"),"Codex")
  XCTAssertEqual(CodexSubscriptionClient.safeLabel(String(repeating:"a",count:100)).count,64)
 }
 /// LE-10: cancelling (as quitting does) deletes the copied sign-in at once, before the async cleanup can run.
 func testCancellingDeletesTheCopiedSignInImmediately()async throws {
  let dir=b10Directory();try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
  let executable=dir.appendingPathComponent("fake-app-server"),credential=dir.appendingPathComponent("fake-auth.json")
  try Data("{\"tokens\":{\"access_token\":\"fake.eyJleHAiOjQxMDI0NDQ4MDB9.signature\",\"refresh_token\":\"fake-refresh\"}}".utf8).write(to:credential)
  let script="""
  #!/usr/bin/python3
  import os, sys, json, pathlib, time
  here = pathlib.Path(__file__).parent
  (here / 'scratch.txt').write_text(str(pathlib.Path(os.environ['CODEX_HOME']).parent))
  for line in sys.stdin:
      request = json.loads(line); method = request['method']
      if method == 'initialized': continue
      if method == 'account/rateLimits/read':
          (here / 'waiting').touch(); time.sleep(10); continue
      result = {'account': {'type': 'chatgpt'}} if method == 'account/read' else {}
      print(json.dumps({'id': request.get('id'), 'result': result}), flush=True)
  """
  try Data(script.utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
  let client=CodexSubscriptionClient(executable:executable,credentialURL:credential,automationAllowed:true,timeout:5)
  let task=Task{try await client.accountStatus()},waiting=dir.appendingPathComponent("waiting")
  for _ in 0..<500 where !FileManager.default.fileExists(atPath:waiting.path){try await Task.sleep(for:.milliseconds(10))}
  let scratch=URL(fileURLWithPath:try String(contentsOf:dir.appendingPathComponent("scratch.txt"),encoding:.utf8)),auth=scratch.appendingPathComponent("codex/auth.json")
  XCTAssertTrue(FileManager.default.fileExists(atPath:auth.path))
  task.cancel();XCTAssertFalse(FileManager.default.fileExists(atPath:auth.path),"The copied sign-in outlived the cancellation")
  do{_=try await task.value;XCTFail("Cancellation succeeded")}catch{XCTAssertTrue(error is CancellationError)}
  for _ in 0..<200 where FileManager.default.fileExists(atPath:scratch.path){try await Task.sleep(for:.milliseconds(20))}
  XCTAssertFalse(FileManager.default.fileExists(atPath:scratch.path))
 }
}

@MainActor final class B10LessonsPuzzleTests:XCTestCase {
 /// LE2-9: a path puzzle keeps its own guidance; a click on a square that is not a king step is not a mistake.
 func testPathPuzzleKeepsItsGuidanceAndIgnoresMisclicks()throws {
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session),id="course:safe-squares:18";player.openPuzzle(id:id)
  player.click("h8");XCTAssertEqual(player.feedback,"Choose a square next to the king.");XCTAssertNil(session.state.puzzles[id],"A misclick is not recorded as a mistake")
  player.click("a2");XCTAssertEqual(player.feedback,"That square is not a safe neighboring square. Try another step.","The rook on a4 attacks a2")
  XCTAssertEqual(session.state.puzzles[id]?.attempts,1);XCTAssertEqual(session.state.puzzles[id]?.review,true);XCTAssertFalse(player.passed)
  player.shutdown()
 }
}
