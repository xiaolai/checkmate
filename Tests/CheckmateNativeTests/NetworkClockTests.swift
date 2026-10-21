import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateMacPlatform

/// B-2: a network clock shows tenths under ten seconds, turns red under twenty, and the learner's own clock warns
/// once per game as it passes twenty seconds, silently under automation.
@MainActor final class NetworkClockTests:XCTestCase {
    func testTenthsShowUnderTenSeconds(){
        XCTAssertEqual(NetworkDetail.clock(9_400),"0:09.4");XCTAssertEqual(NetworkDetail.clock(9_401),"0:09.5","rounded up, as whole seconds are")
        XCTAssertEqual(NetworkDetail.clock(9_950),"0:10","ten seconds and over in whole seconds");XCTAssertEqual(NetworkDetail.clock(10_000),"0:10")
        XCTAssertEqual(NetworkDetail.clock(50),"0:00.1");XCTAssertEqual(NetworkDetail.clock(0),"0:00.0");XCTAssertEqual(NetworkDetail.clock(-5),"0:00.0")
    }
    func testAClockIsLowUnderTwentySeconds(){
        XCTAssertFalse(NetworkDetail.low(20_000));XCTAssertTrue(NetworkDetail.low(19_999));XCTAssertTrue(NetworkDetail.low(0))
    }
    /// The warning sounds once per game, for the learner's own running clock only.
    func testTheLowTimeWarningSoundsOncePerGame(){
        var sounded=0;let warning=NetworkLowTimeWarning{sounded+=1}
        let mine=NetworkClocks(white:19_000,black:60_000,active:.white)
        warning.check(NetworkClocks(white:25_000,black:60_000,active:.white),learner:.white,game:"a");XCTAssertEqual(sounded,0,"above twenty seconds")
        warning.check(NetworkClocks(white:60_000,black:5_000,active:.black),learner:.white,game:"a");XCTAssertEqual(sounded,0,"the opponent's clock")
        warning.check(NetworkClocks(white:5_000,black:60_000,active:.black),learner:.white,game:"a");XCTAssertEqual(sounded,0,"the learner's clock is not running")
        warning.check(mine,learner:nil,game:"a");XCTAssertEqual(sounded,0,"a spectator has no clock of their own")
        warning.check(mine,learner:.white,game:"a");XCTAssertEqual(sounded,1)
        warning.check(NetworkClocks(white:9_000,black:60_000,active:.white),learner:.white,game:"a");XCTAssertEqual(sounded,1,"once per game")
        warning.check(mine,learner:.white,game:"b");XCTAssertEqual(sounded,2,"a new game warns again")
        warning.check(mine,learner:.white,game:nil);XCTAssertEqual(sounded,2,"no game, no warning")
    }
    func testTheWarningSoundIsSilentUnderAutomation(){
        var settings=AppSettings();settings.moveSounds=true;settings.effectsVolume=1
        XCTAssertFalse(NativeAudio(automation:true,scores:[:]).lowTime(settings:settings),"automation never plays")
        settings.moveSounds=false;XCTAssertFalse(NativeAudio(automation:false,scores:[:]).lowTime(settings:settings),"sounds off")
    }
}
