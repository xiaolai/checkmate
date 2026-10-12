public enum CheckmateError: Error, CustomStringConvertible {
    case invalid(String), unavailable(String), stale, cancelled
    public var description:String {switch self {case .invalid(let s),.unavailable(let s):return s;case .stale:return "STALE_STATE";case .cancelled:return "CANCELLED"}}
}
/// `training` is the library, a training exercise, or an existing mini-game opened from the library.
public enum NativeMode:String,Codable {case practice,lesson,puzzles,training}
