import Foundation
public enum ReviewPolicy {
    public static let maximumBytes=16*1024*1024,maximumRecords=1000,maximumMainlinePlies=2000,maximumNodes=10000,maximumDepth=32,pageSize=50,maximumPageSize=100,cacheBytes=256*1024*1024
    public static let quickBudget=500,deepBudget=3000,criticalMomentsToDeepen=5,maximumTitleScalars=256,maximumIndexBytes=2*1024*1024
    /// How many key moments the whole-game analysis checks more deeply: up to five, one fewer for every 20 plies past
    /// 60 and never fewer than one. Each deeper check costs about six seconds, so a 100-ply game stays within its budget.
    public static func momentsToDeepen(plies:Int)->Int {max(1,min(criticalMomentsToDeepen,8-(plies+19)/20))}
    /// The whole-game analysis's time, ten seconds below the 90-second acceptance limit for the app and the engine's start;
    /// what each search costs beyond its budget (measured on the test host under load: 38 ms in a 100-ply game, 69 ms in
    /// a 271-ply one, the second partly the engine's minimum, which its plan's 56 ms budget fell below); and the shortest
    /// quick search, the engine's own minimum, since it runs no shorter one.
    public static let batchBudgetMs=80_000,searchOverheadMs=80,quickFloor=EngineSearchPolicy.minimumMs
    /// The whole-game analysis's worst case: every position searches twice (best and played move) and so does every
    /// deeper moment, whose quick baseline is the batch's own, already stored. A search takes at least the engine's minimum.
    public static func worstCaseMs(plies:Int,_ plan:ReviewBatchPlan)->Int {2*plies*(max(EngineSearchPolicy.minimumMs,plan.quickBudget)+searchOverheadMs)+2*plan.moments*(deepBudget+searchOverheadMs)}
    /// How `plies` positions are analyzed within `batchBudgetMs`: the moments `momentsToDeepen` gives, fewer if the quick
    /// search would fall below the floor, and the longest quick search (at most `quickBudget`) that still fits.
    public static func batchPlan(plies:Int)->ReviewBatchPlan {let plies=max(1,plies)
        for moments in stride(from:momentsToDeepen(plies:plies),through:0,by:-1){let quick=min(quickBudget,(batchBudgetMs-2*moments*(deepBudget+searchOverheadMs))/(2*plies)-searchOverheadMs);if quick>=quickFloor{return ReviewBatchPlan(quickBudget:quick,moments:moments)}}
        return ReviewBatchPlan(quickBudget:quickFloor,moments:0)
    }
    /// The longest game whose worst case fits, 222 plies: past it every search is already at the floor and the budget runs
    /// over. Such a game is still analyzed in full at the floor, about 180 ms a search, and stays cancellable and yields to
    /// the positions the learner chooses.
    public static let longestFittingGame=batchBudgetMs/(2*(quickFloor+searchOverheadMs))
    public static let maximumTokenScalars=1024,maximumTextScalars=1048576,maximumBranches=100,maximumBranchPlies=2000,maximumSavedBytes=64*1024*1024,maximumSavedRecords=1000,maximumLibraryBytes=512*1024*1024
}
/// One whole-game analysis's quick budget per position, in milliseconds, and how many key moments it checks more deeply.
public struct ReviewBatchPlan:Equatable,Sendable {public let quickBudget:Int,moments:Int;public init(quickBudget:Int,moments:Int){self.quickBudget=quickBudget;self.moments=moments}}
/// The shortest search the engine runs: it raises any shorter time budget to this, so a budget model must too.
public enum EngineSearchPolicy {public static let minimumMs=100}
