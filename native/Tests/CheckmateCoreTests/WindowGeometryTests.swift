import XCTest
@testable import CheckmateCore
final class WindowGeometryTests:XCTestCase {
    func testInitialWindowSquareAndRestorationClamped(){let screen=CGRect(x:0,y:0,width:1728,height:1084);let initial=WindowGeometry.restored(nil,screens:[screen]);XCTAssertEqual(initial.width,initial.height);let restored=WindowGeometry.restored([99999,-9999,9000,9000],screens:[screen]);XCTAssertTrue(screen.contains(restored));XCTAssertEqual(restored.size,screen.size)}
    func testInvalidAndDisconnectedScreenRestoration(){let screen=CGRect(x:0,y:0,width:800,height:650);let r=WindowGeometry.restored([Double.nan,0,10,10],screens:[screen]);XCTAssertTrue(screen.contains(r));XCTAssertEqual(r.height,650)}
}
