import Foundation
import XCTest
import AppKit
@testable import CheckmateNative

extension XCTestCase {
    /// A unique URL under the temporary directory, removed when the test ends; `create` makes the directory now.
    func scratchDirectory(_ prefix:String="",create:Bool=false)throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(prefix+UUID().uuidString)
        if create{try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
        addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
    }
    /// A fresh data directory in `CHECKMATE_DATA_DIR`, with `extra` variables set alongside; all undone when the test ends.
    @discardableResult func isolateDataDirectory(_ extra:[String:String]=[:],prefix:String="")throws -> URL {
        let url=try scratchDirectory(prefix,create:true);setEnvironment(["CHECKMATE_DATA_DIR":url.path].merging(extra){$1});return url
    }
    /// Sets each variable now and unsets it when the test ends.
    func setEnvironment(_ vars:[String:String]){
        for (name,value) in vars{setenv(name,value,1)}
        addTeardownBlock{for name in vars.keys{unsetenv(name)}}
    }
}

struct PollTimeout:Error {let what:String}
/// Checks `condition` up to `tries` times, `every` apart, and once more at the end; fails and throws if it never holds.
@MainActor func poll(_ what:String,tries:Int,every:Duration,file:StaticString=#filePath,line:UInt=#line,_ condition:()->Bool)async throws {
    for _ in 0..<tries{if condition(){return};try await Task.sleep(for:every)}
    if condition(){return};XCTFail("timed out waiting for \(what)",file:file,line:line);throw PollTimeout(what:what)
}
/// Checks `condition` up to `tries` times, `every` apart (`.zero` yields instead of sleeping), and returns either way.
@MainActor func pollQuietly(tries:Int,every:Duration,_ condition:()->Bool)async {
    for _ in 0..<tries{if condition(){return};if every == .zero{await Task.yield()}else{try? await Task.sleep(for:every)}}
}
@MainActor func yields(_ n:Int)async {for _ in 0..<n{await Task.yield()}}

func mouseEvent(_ type:NSEvent.EventType,_ point:NSPoint,_ modifiers:NSEvent.ModifierFlags=[])->NSEvent {NSEvent.mouseEvent(with:type,location:point,modifierFlags:modifiers,timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
extension BoardView {
    /// A press, a drag and a release through the board's own handlers, in its coordinates.
    func drag(from:String,to:String){
        let a=squareRect(from),b=squareRect(to)
        mouseDown(with:mouseEvent(.leftMouseDown,NSPoint(x:a.midX,y:a.midY)));mouseDragged(with:mouseEvent(.leftMouseDragged,NSPoint(x:b.midX,y:b.midY)));mouseUp(with:mouseEvent(.leftMouseUp,NSPoint(x:b.midX,y:b.midY)))
    }
}
extension NativeModel {
    func testBar(voice:ControlBarVoice = .off(unavailable:nil),trainingVoice:Bool=false)->ControlBarModel {
        ControlBarModel.make(session:session,learning:learning,review:review,training:training,network:network,voice:voice,trainingVoice:trainingVoice)
    }
}
