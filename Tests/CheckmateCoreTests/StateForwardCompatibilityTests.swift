import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// PL2-11: a state file written by a newer build keeps the fields this build does not know through a load and a save,
/// so a downgrade followed by a re-upgrade loses nothing; fields this build writes stay this build's to change.
final class StateForwardCompatibilityTests:XCTestCase {
    private var directory:URL!
    override func setUpWithError() throws {directory=FileManager.default.temporaryDirectory.appendingPathComponent("forward-"+UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
    override func tearDown(){try? FileManager.default.removeItem(at:directory)}

    /// A state as a newer build would write it: today's fields plus new ones at the top level and inside each object.
    private func newerState(ending:Bool=false)throws -> StateStore {
        let store=StateStore(directory:directory)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(ApplicationState())) as? [String:Any])
        object["futureFeature"]=["enabled":true,"count":7]
        func add(_ key:String,_ field:String,_ value:Any){var inner=object[key] as? [String:Any] ?? [:];inner[field]=value;object[key]=inner}
        add("settings","futureSetting","x");add("practice","futureSide","b");add("course","futureTrack","endgames");add("window","futureDock",3)
        add("miniGames","future-kind",["level":2])
        if ending{add("practice","ending",["result":"1-0","reason":"resignation"])}
        try JSONSerialization.data(withJSONObject:object).write(to:store.url);return store
    }
    private func saved(_ url:URL)throws -> [String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])}

    func testUnknownFieldsSurviveALoadAndASave()throws {
        let store=try newerState();var state=try store.load();state.settings.skill=5;try store.save(state)
        let written=try saved(store.url)
        XCTAssertEqual((written["settings"] as? [String:Any])?["skill"] as? Int,5,"the known field was not updated")
        XCTAssertEqual(written["futureFeature"] as? [String:Any] as NSDictionary?,["enabled":true,"count":7] as NSDictionary,"a newer top-level field was dropped")
        XCTAssertEqual((written["settings"] as? [String:Any])?["futureSetting"] as? String,"x","a newer setting was dropped")
        XCTAssertEqual((written["practice"] as? [String:Any])?["futureSide"] as? String,"b","a newer practice field was dropped")
        XCTAssertEqual((written["course"] as? [String:Any])?["futureTrack"] as? String,"endgames","a newer course field was dropped")
        XCTAssertEqual((written["window"] as? [String:Any])?["futureDock"] as? Int,3,"a newer window field was dropped")
        XCTAssertEqual(((written["miniGames"] as? [String:Any])?["future-kind"] as? [String:Any])?["level"] as? Int,2,"a newer mini-game's progress was dropped")
        // The saved file loads again and keeps them through a second save.
        try store.save(try store.load());XCTAssertEqual((try saved(store.url)["settings"] as? [String:Any])?["futureSetting"] as? String,"x")
    }
    func testAnExportKeepsUnknownFields()throws {
        let store=try newerState(),destination=directory.appendingPathComponent("export.json")
        try store.exportState(try store.load(),to:destination)
        XCTAssertNotNil(try saved(destination)["futureFeature"],"an export dropped a newer field")
    }
    func testAFieldThisBuildWritesIsNeverResurrected()throws {
        let store=try newerState(ending:true);var state=try store.load()
        XCTAssertEqual(state.practice.ending?.result,"1-0","fixture: the ending did not load");state.practice.ending=nil;try store.save(state)
        XCTAssertNil((try saved(store.url)["practice"] as? [String:Any])?["ending"],"a cleared known field came back from the loaded file")
        XCTAssertNil(try store.load().practice.ending)
    }
    func testAFreshStateCarriesNothingAndNewerSchemasAreStillRefused()throws {
        let store=StateStore(directory:directory);try store.save(ApplicationState())
        XCTAssertNil(try saved(store.url)["futureFeature"])
        var object=try saved(store.url);object["schemaVersion"]=2;try JSONSerialization.data(withJSONObject:object).write(to:store.url)
        XCTAssertThrowsError(try store.load(),"a newer schema must still be refused")
    }
}
