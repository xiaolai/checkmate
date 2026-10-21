import Foundation
/// The threads and hash table one search may use. Practice and every other search keep `AnalysisPolicy`'s single
/// thread and small hash; review analysis asks for more (R-5), per search, since the engine is shared.
public struct EngineResources:Equatable,Sendable {
    public let threads:Int,hashMB:Int
    public init(threads:Int,hashMB:Int){self.threads=max(1,threads);self.hashMB=max(1,hashMB)}
    /// All cores but two, so the app and the Mac stay responsive, and a hash that keeps the review batch within its
    /// memory budget.
    public static func review(processors:Int=ProcessInfo.processInfo.activeProcessorCount)->Self {Self(threads:max(1,processors-2),hashMB:128)}
    /// The UCI options that apply them, over `AnalysisPolicy.options`.
    public var options:[String:String] {["Threads":String(threads),"Hash":String(hashMB)]}
}
