import CheckmateAssets
import Foundation
public struct ReviewImportError:Error,LocalizedError {public init(record:Int,token:Int,reason:String){self.record=record;self.token=token;self.reason=reason}
public let record:Int,token:Int,reason:String;public var errorDescription:String? {"Record \(record), token \(token): \(reason)"}}
