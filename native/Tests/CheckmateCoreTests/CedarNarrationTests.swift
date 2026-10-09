import XCTest
import AVFoundation
@testable import CheckmateCore

final class CedarNarrationTests:XCTestCase {
    func testEveryBundledCedarClipDecodesAndMatchesPlaybackDuration() throws {
        let course=try CourseLibrary()
        XCTAssertEqual(course.lessonTiming,CourseTiming.standard)
        var count=0
        for (li,lesson) in course.lessons.enumerated() {
            XCTAssertEqual(course.voices[li].count,lesson.beats.count)
            XCTAssertEqual(course.stepTitles[li].count,lesson.beats.count)
            for (step,voice) in course.voices[li].enumerated() {
                XCTAssertTrue(voice.file.hasPrefix("course/cedar-"))
                let player=try AVAudioPlayer(contentsOf:NativeResources.url(voice.file))
                XCTAssertEqual(player.duration,voice.seconds,accuracy:0.001,"\(lesson.id):\(step)")
                XCTAssertGreaterThanOrEqual(voice.duration,voice.seconds+course.lessonTiming.postNarrationGap)
                XCTAssertFalse(lesson.beats[step].say.contains("pause the lesson"))
                count+=1
            }
        }
        XCTAssertEqual(count,947)
    }

    @MainActor func testPlaybackUsesCedarAssetAndKeepsSavedTranscriptPosition() throws {
        var state=ApplicationState();state.course.lessonID="pawn";state.course.step=7
        let session=try GameSession(engine:nil,state:state),player=try LearningPlayer(session:session)
        let audio=RecordingNarrationSpy();player.audio=audio
        player.openLesson(index:player.lessonIndex);player.play()
        XCTAssertEqual(player.key,"pawn:7")
        XCTAssertEqual(audio.file,player.library.voices[player.lessonIndex][7].file)
        XCTAssertTrue(audio.file.hasPrefix("course/cedar-"))
        player.pause()
    }
}

@MainActor private final class RecordingNarrationSpy:NarrationService {
    var file=""
    func play(file:String,seconds:Double,settings:AppSettings){self.file=file}
    func pause(){}
    func stop(){}
}
