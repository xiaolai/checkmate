import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class WindowGeometryTests:XCTestCase {
    func testInitialWindowSquareAndRestorationClamped(){let screen=CGRect(x:0,y:0,width:1728,height:1084);let initial=WindowGeometry.restored(nil,screens:[screen]);XCTAssertEqual(initial.width,initial.height);let restored=WindowGeometry.restored([99999,-9999,9000,9000],screens:[screen]);XCTAssertTrue(screen.contains(restored));XCTAssertEqual(restored.size,CGSize(width:1084,height:1084),"Clamping keeps the board area square")
        let drawers=WindowGeometry.restored([0,0,2000,1400],screens:[screen],drawers:536);XCTAssertEqual(drawers.height,1084);XCTAssertEqual(drawers.width,1084+536);XCTAssertTrue(screen.contains(drawers))
        let narrow=WindowGeometry.restored([0,0,1500,900],screens:[CGRect(x:0,y:0,width:1280,height:1000)],drawers:536);XCTAssertEqual(narrow.width,1280);XCTAssertEqual(narrow.height,1280-536,"The screen's width limits the board side when drawers are open")}
    func testInvalidAndDisconnectedScreenRestoration(){let screen=CGRect(x:0,y:0,width:800,height:650);let r=WindowGeometry.restored([Double.nan,0,10,10],screens:[screen]);XCTAssertTrue(screen.contains(r));XCTAssertEqual(r.height,650)}
}
