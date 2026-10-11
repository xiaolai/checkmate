import Foundation
import Combine

public enum UsageActivity: String, Codable, CaseIterable, Sendable { case translation, lessonRecording, voiceCoach, inputTranscription }
public enum UsageStatus: String, Codable, Sendable { case running, completed, failed, cancelled, incomplete }
public enum UsageTimeRange: String, CaseIterable { case today, thisMonth, all }
public enum UsageLimits {
    public static let maximumCounter:Int64 = 1_000_000_000_000
    public static let maximumRecords = 10_000
    public static let maximumFileBytes = 16*1024*1024
    public static let maximumDuration:Double = 86400
    public static let maximumEstimate:Double = 1_000_000_000
    public static let retentionDays = 365
    public static let maximumPCMBytes:Int64 = 48000*86400
}
public struct UsageTokens: Codable, Equatable, Sendable {
    public let input: Int64?, output: Int64?, total: Int64?, cachedInput: Int64?, reasoning: Int64?
    public let inputText: Int64?, inputAudio: Int64?, outputText: Int64?, outputAudio: Int64?, cachedText: Int64?, cachedAudio: Int64?
    public init(input: Int64? = nil, output: Int64? = nil, total: Int64? = nil, cachedInput: Int64? = nil, reasoning: Int64? = nil, inputText:Int64?=nil, inputAudio:Int64?=nil, outputText:Int64?=nil, outputAudio:Int64?=nil, cachedText:Int64?=nil, cachedAudio:Int64?=nil) {
        func valid(_ n: Int64?) -> Int64? { guard let n, n >= 0, n <= UsageLimits.maximumCounter else { return nil }; return n }
        self.input=valid(input); self.output=valid(output); self.total=valid(total); self.cachedInput=valid(cachedInput); self.reasoning=valid(reasoning)
        self.inputText=valid(inputText);self.inputAudio=valid(inputAudio);self.outputText=valid(outputText);self.outputAudio=valid(outputAudio);self.cachedText=valid(cachedText);self.cachedAudio=valid(cachedAudio)
    }
    public var known: Bool { input != nil || output != nil || total != nil }
    public static func parseRealtime(_ payload: [String:Any]?) -> UsageTokens? {
        guard let p=payload else{return nil}
        let input=p["input_token_details"] as? [String:Any] ?? [:],output=p["output_token_details"] as? [String:Any] ?? [:],cached=input["cached_tokens_details"] as? [String:Any] ?? [:]
        let result=UsageTokens(input:counter(p["input_tokens"]),output:counter(p["output_tokens"]),total:counter(p["total_tokens"]),cachedInput:counter(input["cached_tokens"]),inputText:counter(input["text_tokens"]),inputAudio:counter(input["audio_tokens"]),outputText:counter(output["text_tokens"]),outputAudio:counter(output["audio_tokens"]),cachedText:counter(cached["text_tokens"]),cachedAudio:counter(cached["audio_tokens"]))
        return result.known ? result : nil
    }
    public static func parseCodex(_ payload: [String:Any]?) -> UsageTokens? {
        guard let p=payload else{return nil}
        let result=UsageTokens(input: counter(p["inputTokens"]),output: counter(p["outputTokens"]),total: counter(p["totalTokens"]),cachedInput: counter(p["cachedInputTokens"]),reasoning: counter(p["reasoningOutputTokens"]))
        return result.known ? result : nil
    }
    private static func counter(_ value: Any?) -> Int64? {
        guard let number=value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else{return nil}
        let d=number.doubleValue; guard d.isFinite,d >= 0,d <= Double(UsageLimits.maximumCounter),d.rounded()==d else{return nil};return Int64(d)
    }
}
import CoreFoundation
public struct UsageRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var activity: UsageActivity
    public var provider: String
    public var sessionID: String
    public var providerID: String?
    public var model: String?, locale: String?, voice: String?, lessonID: String?
    public var startedAt: Date, updatedAt: Date
    public var status: UsageStatus
    public var tokens: UsageTokens?
    public var durationSeconds: Double?
    public var estimatedCredits: Double?, estimatedUSD: Double?
}
public struct UsageTotals: Equatable {
    public var input: Int64=0, output: Int64=0, total: Int64=0
    public var knownRecords: Int=0, unknownRecords: Int=0, incompleteRecords: Int=0
}
@MainActor public final class UsageLedger: ObservableObject {
    @Published public private(set) var records: [UsageRecord]=[]
    @Published public private(set) var storageError: String?
    public let directory: URL
    @Published public private(set) var unavailable=false
    private var rejectedRootSymlink=false
    private let persistenceQueue=DispatchQueue(label:"ai.xiaolai.checkmate.usage-persistence",qos:.utility)
    private var pendingPersistence:DispatchWorkItem?
    private var persistenceRevision=0
    private struct File: Codable, Sendable { var version: Int=1; var records:[UsageRecord] }
    public init(directory: URL) {
        let suppliedRootIsSymlink=(try? directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true
        self.directory=directory.resolvingSymlinksInPath()
        if suppliedRootIsSymlink{rejectedRootSymlink=true;unavailable=true;storageError="Usage history is unavailable because its directory is a symbolic link.";return}
        let url=self.directory.appendingPathComponent("usage-v1.json")
        guard FileManager.default.fileExists(atPath:url.path) else{return}
        do {
            try checkDirectory()
            let values=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]);guard values.isSymbolicLink != true,(values.fileSize ?? 0)<=UsageLimits.maximumFileBytes else{throw CocoaError(.fileReadCorruptFile)}
            let file=try JSONDecoder().decode(File.self,from:Data(contentsOf:url));guard file.version==1,file.records.count<=UsageLimits.maximumRecords,file.records.allSatisfy(Self.valid) else{throw CocoaError(.fileReadCorruptFile)}
            records=file.records.map { var r=$0;if r.status == .running {r.status = .incomplete};return r }
        }catch{unavailable=true;storageError="Usage history is unavailable. The original file has been preserved."}
    }
    private static func valid(_ r:UsageRecord)->Bool {
        let strings=[r.id,r.provider,r.sessionID,r.providerID ?? "",r.model ?? "",r.locale ?? "",r.voice ?? "",r.lessonID ?? ""]
        guard strings.allSatisfy({$0.utf8.count<=256}),r.startedAt.timeIntervalSince1970.isFinite,r.updatedAt.timeIntervalSince1970.isFinite else{return false}
        if let d=r.durationSeconds,(!d.isFinite || d<0 || d>UsageLimits.maximumDuration){return false}
        if let t=r.tokens {for n in [t.input,t.output,t.total,t.cachedInput,t.reasoning,t.inputText,t.inputAudio,t.outputText,t.outputAudio,t.cachedText,t.cachedAudio] {if let n,n<0 || n>UsageLimits.maximumCounter{return false}}}
        for estimate in [r.estimatedCredits,r.estimatedUSD]{if let estimate,(!estimate.isFinite || estimate<0 || estimate>UsageLimits.maximumEstimate){return false}}
        return true
    }
    @discardableResult public func begin(activity:UsageActivity,provider:String,sessionID:String,model:String?=nil,locale:String?=nil,voice:String?=nil,lessonID:String?=nil)->String {
        let id=UUID().uuidString,now=Date();guard !unavailable else{return id}
        records.append(UsageRecord(id:id,activity:activity,provider:String(provider.prefix(256)),sessionID:String(sessionID.prefix(256)),model:model.map{String($0.prefix(256))},locale:locale.map{String($0.prefix(256))},voice:voice.map{String($0.prefix(256))},lessonID:lessonID.map{String($0.prefix(256))},startedAt:now,updatedAt:now,status:.running));persist();return id
    }
    public func record(operationID:String,providerID:String?,tokens:UsageTokens?,status:UsageStatus,cumulative:Bool=false,durationSeconds:Double?=nil,estimatedCredits:Double?=nil,estimatedUSD:Double?=nil,model:String?=nil) {
        guard let index=records.firstIndex(where:{$0.id==operationID}) else{return}
        let original=records[index]
        if let providerID,!cumulative,records.contains(where:{$0.id != operationID && $0.provider==original.provider && $0.sessionID==original.sessionID && $0.providerID==providerID && $0.activity==original.activity}){records.remove(at:index);persist();return}
        if !cumulative,original.providerID != nil,original.status != .running,original.status != .incomplete{return}
        records[index].providerID=providerID.map{String($0.prefix(256))};records[index].tokens=tokens;if !(status == .running && original.status != .running){records[index].status=status};records[index].updatedAt=Date()
        if let model{records[index].model=String(model.prefix(256))}
        if let d=durationSeconds,d.isFinite,d>=0,d<=UsageLimits.maximumDuration{records[index].durationSeconds=d}
        if let estimate=estimatedCredits,estimate.isFinite,estimate>=0,estimate<=UsageLimits.maximumEstimate{records[index].estimatedCredits=estimate}
        if let estimate=estimatedUSD,estimate.isFinite,estimate>=0,estimate<=UsageLimits.maximumEstimate{records[index].estimatedUSD=estimate}
        persist()
    }
    public func finish(operationID:String,status:UsageStatus){guard let i=records.firstIndex(where:{$0.id==operationID}),records[i].status == .running else{return};records[i].status=status;records[i].updatedAt=Date();persist()}
    public func records(in range:UsageTimeRange,now:Date=Date(),calendar:Calendar = .current)->[UsageRecord] {
        let start:Date?;switch range{case .all:start=nil;case .today:start=calendar.startOfDay(for:now);case .thisMonth:start=calendar.dateInterval(of:.month,for:now)?.start}
        return records.filter { (start == nil || $0.startedAt>=start!) && $0.startedAt<=now }
    }
    public func totals(in range:UsageTimeRange = .all,now:Date=Date())->UsageTotals {
        var sum=UsageTotals();for r in records(in:range,now:now){if r.status == .incomplete || r.status == .running{sum.incompleteRecords+=1};guard let t=r.tokens,t.known else{sum.unknownRecords+=1;continue};sum.knownRecords+=1;sum.input += t.input ?? 0;sum.output += t.output ?? 0;sum.total += t.total ?? 0};return sum
    }
    public func exportJSON() throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601;return try encoder.encode(File(records:records))}
    public func clear() throws {
        try checkDirectory()
        records.removeAll{$0.status != .running};unavailable=false;storageError=nil;persist()
    }
    /// Enqueues the current snapshot for application shutdown without blocking the main actor.
    public func schedulePersistenceFlush() {persist(immediate:true)}
    /// A bounded final drain, used only when the application is terminating.
    public func flushForShutdown(timeout:TimeInterval=1) {
        guard !unavailable else{return}
        pendingPersistence?.cancel();pendingPersistence=nil
        let snapshot=records,root=directory,done=DispatchSemaphore(value:0)
        persistenceQueue.async {
            defer{done.signal()}
            try? Self.writeSnapshot(try JSONEncoder().encode(File(records:snapshot)),to:root)
        }
        _=done.wait(timeout:.now()+max(0,min(timeout,2)))
    }
    /// Waits off the main actor until the latest in-memory snapshot is durably written.
    public func flush() async throws {
        guard !unavailable else{throw CocoaError(.fileReadCorruptFile)}
        pendingPersistence?.cancel();pendingPersistence=nil
        try checkDirectory()
        let snapshot=records,root=directory
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            persistenceQueue.async {
                do{try Self.writeSnapshot(try JSONEncoder().encode(File(records:snapshot)),to:root);continuation.resume()}catch{continuation.resume(throwing:error)}
            }
        }
    }
    private func checkDirectory() throws {
        guard !rejectedRootSymlink else{throw CocoaError(.fileWriteNoPermission)}
        try Self.checkStoragePath(directory)
    }
    private nonisolated static func checkStoragePath(_ directory:URL) throws {
        var current=directory.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath:current.path),try current.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true {
                let destination=try FileManager.default.destinationOfSymbolicLink(atPath:current.path)
                let systemAlias=(current.path == "/var" && ["private/var","/private/var"].contains(destination)) || (current.path == "/tmp" && ["private/tmp","/private/tmp"].contains(destination))
                guard systemAlias else{throw CocoaError(.fileWriteNoPermission)}
            }
            current.deleteLastPathComponent()
        }
    }
    nonisolated static func writeSnapshot(_ data:Data,to directory:URL) throws {
        guard data.count<=UsageLimits.maximumFileBytes else{throw CocoaError(.fileWriteOutOfSpace)}
        // Recheck after scheduling, since the directory may have changed while queued.
        try checkStoragePath(directory)
        let rootValues=try? directory.resourceValues(forKeys:[.isSymbolicLinkKey])
        guard rootValues?.isSymbolicLink != true else{throw CocoaError(.fileWriteNoPermission)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=directory.appendingPathComponent("usage-v1.json")
        if FileManager.default.fileExists(atPath:url.path),try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true{throw CocoaError(.fileWriteNoPermission)}
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func persist(immediate:Bool=false) {
        guard !unavailable else{return}
        let cutoff=Date().addingTimeInterval(-Double(UsageLimits.retentionDays)*86400);records.removeAll{$0.updatedAt<cutoff};if records.count>UsageLimits.maximumRecords{records.removeFirst(records.count-UsageLimits.maximumRecords)}
        do {
            try checkDirectory()
            let snapshot=records,root=directory
            pendingPersistence?.cancel();persistenceRevision+=1;let revision=persistenceRevision
            let work=DispatchWorkItem { [weak self] in
                let message:String?
                do{try Self.writeSnapshot(try JSONEncoder().encode(File(records:snapshot)),to:root);message=nil}catch{message="Usage history could not be saved."}
                Task { @MainActor [weak self] in guard let self,self.persistenceRevision==revision else{return};self.storageError=message }
            }
            pendingPersistence=work
            if immediate{persistenceQueue.async(execute:work)}else{persistenceQueue.asyncAfter(deadline:.now()+0.1,execute:work)}
        }catch{storageError="Usage history could not be saved."}
    }
}
