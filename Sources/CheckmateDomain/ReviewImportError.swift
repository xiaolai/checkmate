import CheckmateAssets
import Foundation
/// A PGN import problem. One inside a game names its record and token; one about the file as a whole (its size, its
/// text, its number of games) has no such place and shows its reason alone.
public struct ReviewImportError:Error,LocalizedError {public init(record:Int,token:Int,reason:String){self.location=(record,token);self.reason=reason}
public init(file reason:String){self.location=nil;self.reason=reason}
public let location:(record:Int,token:Int)?,reason:String;public var record:Int? {location?.record}
public var errorDescription:String? {location.map{String(localized:"Record \($0.record), token \($0.token): \(reason)",bundle:.checkmate)} ?? reason}}
