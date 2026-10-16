import Foundation
import JavaScriptCore
import CheckmateDomain
import CheckmateAssets
/// Each rules instance owns an isolated runtime. A platform adapter supplies the same chess.js contract.
public protocol ChessScriptRuntime:AnyObject {func evaluate(_ script:String)throws -> String}
public final class JavaScriptCoreChessRuntime:ChessScriptRuntime {
    private static let lock=NSLock()
    private static var created=0
    /// Runtimes made so far in this process. Each owns a JavaScript virtual machine with its own JIT, so a path that runs
    /// on every refresh must not add to it.
    public static var instancesCreated:Int {lock.lock();defer{lock.unlock()};return created}
    private let context:JSContext
    public init()throws {
        Self.lock.lock();Self.created+=1;Self.lock.unlock()
        guard let context=JSContext() else{throw CheckmateError.unavailable("Chess rules could not initialize.")};self.context=context
        context.evaluateScript("var exports={};")
        context.evaluateScript(try String(contentsOf:NativeResources.url("chess.js"),encoding:.utf8))
        guard context.exception==nil else{throw CheckmateError.unavailable("Chess rules resource is invalid.")}
        context.evaluateScript("var game=new exports.Chess();")
    }
    public func evaluate(_ script:String)throws -> String {
        context.exception=nil
        guard let value=context.evaluateScript(script)?.toString(),context.exception==nil else{throw CheckmateError.invalid("Invalid chess operation.")}
        return value
    }
}
