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

@MainActor final class LearningLocalizationPlaybackTests:XCTestCase {
 func testPackSelectionNeverChangesPracticeOrMiniGame()async throws {let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let session=try GameSession(engine:nil),player=try LearningPlayer(session:session),store=try LessonPackStore(directory:dir);let mode=session.mode,fen=session.rules.fen;player.packs=store;XCTAssertEqual(session.mode,mode);XCTAssertEqual(session.rules.fen,fen);session.state.settings.lessonLanguage="fr";player.settingsChanged();try await Task.sleep(for:.milliseconds(100));XCTAssertEqual(session.mode,mode);XCTAssertEqual(session.rules.fen,fen);player.startMini(.pawnDuel);let mini=player.miniGame;player.reloadLocalizedPacks();try await Task.sleep(for:.milliseconds(100));XCTAssertEqual(player.miniGame,mini);XCTAssertTrue(player.mini);player.shutdown()}
 func testShortAndLongClipsKeepAllAuthoredActions()async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let library=try CourseLibrary(),source=LessonTranslation.source(library:library,index:19),store=try LessonPackStore(directory:dir);try store.saveTranslation(source,source:source,locale:"fr")
  for (index,beat) in source.beats.enumerated(){_ = try store.saveClip(pcm:plausibleLessonPCM(beat.speak,seconds:index==0 ? 30:0),transcript:beat.speak,beatID:beat.id,source:source,locale:"fr",voice:"cedar",model:"gpt-realtime")}
  let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);session.state.settings.lessonLanguage="fr";session.state.settings.autoAdvance=false;player.openLesson(index:19);player.packs=store
  for _ in 0..<100 {if player.fallbackMessage==nil{break};try await Task.sleep(for:.milliseconds(10))};XCTAssertNil(player.fallbackMessage)
  player.openLesson(index:19);XCTAssertGreaterThanOrEqual(player.duration,30+library.lessonTiming.postNarrationGap)
  for index in source.beats.indices {player.seek(step:index);player.play();player.advance(by:player.duration);XCTAssertEqual(player.frame.board,library.referenceFrames[19][index].end.board);XCTAssertEqual(player.frame.counts,library.lessons[19].beats[index].count);XCTAssertFalse(player.playing)};player.shutdown()
 }
}
