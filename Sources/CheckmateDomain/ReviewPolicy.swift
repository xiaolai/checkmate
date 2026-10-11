import Foundation
public enum ReviewPolicy {
    public static let maximumBytes=16*1024*1024,maximumRecords=1000,maximumMainlinePlies=2000,maximumNodes=10000,maximumDepth=32,pageSize=50,maximumPageSize=100,cacheBytes=256*1024*1024
    public static let quickBudget=500,deepBudget=3000,criticalMomentsToDeepen=1,maximumTitleScalars=256,maximumIndexBytes=2*1024*1024
    public static let maximumTokenScalars=1024,maximumTextScalars=1048576,maximumBranches=100,maximumBranchPlies=2000,maximumSavedBytes=64*1024*1024,maximumSavedRecords=1000,maximumLibraryBytes=512*1024*1024
}
