import CheckmateDomain
import CheckmateSupport
import Foundation
public struct SavedReview:Codable {public let schemaVersion:Int,document:GameDocument;public var cursor:Int,branches:[ReviewBranch],updatedAt:Date}
public struct ReviewIndexEntry:Codable,Identifiable {public let id:UUID,title:String,result:String,updatedAt:Date}
/// Call from an I/O task. Cached validation/index avoid reparsing the library on cursor saves.
public final class ReviewStore {
    private let lock=NSRecursiveLock()
    private let atomicWriter:(Data,URL)throws->Void
    private var index:[ReviewIndexEntry]?
    private var persisted:[UUID:GameDocument]=[:]
    private var schemaCache:[String:(stamp:String,future:Bool)]=[:]
    private var preserved:[UUID:String]=[:]
    private var validated:[UUID:GameDocument]=[:]
    private var stamps:[UUID:String]=[:]
    private var branchCache:[UUID:[ReviewBranch]]=[:]
    /// Content hash of each saved record's original text, kept in the index so a repeated open can find its record.
    private var hashes:[UUID:String]=[:]
    private var quarantinedSinceTaken=0
    private struct Cursor:Codable {let schemaVersion:Int,cursor:Int,updatedAt:Date}
    /// `hashes` is absent from indexes written before it existed; readers that predate it ignore it.
    private struct Index:Codable {let schemaVersion:Int,entries:[ReviewIndexEntry],stamps:[String:String],hashes:[String:String]?}
    private func futureSchema(_ url:URL)->Bool {
        let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]);if (values?.fileSize ?? 0)>ReviewPolicy.maximumSavedBytes{return true};let identity="\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached=schemaCache[url.path],cached.stamp==identity{return cached.future}
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=ReviewPolicy.maximumSavedBytes,let data=try? Data(contentsOf:url),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let version=object["schemaVersion"] as? Int else{return false}
        schemaCache[url.path]=(identity,version>1);return version>1
    }
    private func cursorURL(_ id:UUID)->URL {directory.appendingPathComponent(id.uuidString+".cursor.json")}
    private func saveCursor(_ id:UUID,cursor:Int,date:Date)throws {guard !futureSchema(cursorURL(id)) else{return};try atomicWriter(JSONEncoder().encode(Cursor(schemaVersion:1,cursor:cursor,updatedAt:date)),cursorURL(id))}
    private func stamp(_ id:UUID)->String {let values=try? documentURL(id).resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]);return "\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"}
    public let directory:URL
    public convenience init(directory:URL){self.init(directory:directory,atomicWriter:{try $0.write(to:$1,options:.atomic)})}
    /// Internal fault-injection seam; production writes retain Foundation atomic replacement.
    init(directory:URL,atomicWriter:@escaping(Data,URL)throws->Void){self.directory=directory;self.atomicWriter=atomicWriter}
    public func documentURL(_ id:UUID)->URL {directory.appendingPathComponent(id.uuidString+".json")}
    private func prepare()throws {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    private func validate(_ document:GameDocument)throws {if validated[document.id] != document{try document.validate();validated[document.id]=document}}
    /// The stored document, or the current importer's reading of its verified original when the stored tree differs
    /// (an importer or chess.js update), so a saved review is never refused only because the reader changed.
    private func readable(_ document:GameDocument)throws -> GameDocument {
        if validated[document.id]==document{return document}
        let current=try ImportedDocuments.shared.built(document) ? document:document.rederived()
        validated[document.id]=current;return current
    }
    private func validateBranches(_ branches:[ReviewBranch],document:GameDocument)throws {
        guard branches.count<=ReviewPolicy.maximumBranches,Set(branches.map(\.id)).count==branches.count else{throw CheckmateError.invalid("Invalid saved branches.")}
        for branch in branches{let rules=try document.snapshotRules(at:branch.root);guard branch.moves.count<=ReviewPolicy.maximumBranchPlies else{throw CheckmateError.invalid("Branch too long.")};for move in branch.moves{try rules.move(uci:move)}}
    }
    public func save(_ document:GameDocument,cursor:Int,branches:[ReviewBranch])throws {
        lock.lock();defer{lock.unlock()};try prepare();guard !futureSchema(documentURL(document.id)) else{throw CheckmateError.unavailable("This review requires a newer Checkmate version; its file is preserved.")};try validate(document)
        guard document.nodes.indices.contains(cursor) else{throw CheckmateError.invalid("Invalid saved review cursor.")}
        var entries=try list()
        if branchCache[document.id]==branches,entries.contains(where:{$0.id==document.id}),persisted[document.id]==document,!futureSchema(cursorURL(document.id)) {
            let date=Date();try saveCursor(document.id,cursor:cursor,date:date)
            entries.removeAll{$0.id==document.id};entries.append(ReviewIndexEntry(id:document.id,title:document.title,result:document.result,updatedAt:date));index=entries.sorted{$0.updatedAt>$1.updatedAt};try writeIndex();return
        }
        try validateBranches(branches,document:document)
        guard entries.contains(where:{$0.id==document.id}) || entries.count<ReviewPolicy.maximumSavedRecords else{throw CheckmateError.invalid("Review library record limit reached.")}
        let saved=SavedReview(schemaVersion:1,document:document,cursor:cursor,branches:branches,updatedAt:Date()),data=try JSONEncoder().encode(saved)
        guard data.count<=ReviewPolicy.maximumSavedBytes else{throw CheckmateError.invalid("Saved review exceeds storage limit.")}
        let enumerator=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])
        var total=0
        while let file=enumerator?.nextObject() as? URL {if file==documentURL(document.id){continue};let values=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);if values.isRegularFile==true{total+=values.fileSize ?? 0}}
        guard total+data.count<=ReviewPolicy.maximumLibraryBytes else{throw CheckmateError.invalid("Review library storage limit reached; export or delete older reviews.")}
        let url=documentURL(document.id);try atomicWriter(data,url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        guard try Data(contentsOf:url)==data else{throw CheckmateError.unavailable("Review read-back failed.")}
        persisted[document.id]=document;hashes[document.id]=document.contentHash
        entries.removeAll{$0.id==document.id};entries.append(ReviewIndexEntry(id:document.id,title:document.title,result:document.result,updatedAt:saved.updatedAt));index=entries.sorted{$0.updatedAt>$1.updatedAt};stamps[document.id]=stamp(document.id);branchCache[document.id]=branches;try saveCursor(document.id,cursor:cursor,date:saved.updatedAt);try writeIndex()
    }
    public func load(_ id:UUID)throws -> SavedReview {
        lock.lock();defer{lock.unlock()};let url=documentURL(id),size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size<=ReviewPolicy.maximumSavedBytes else{throw CheckmateError.unavailable("This review is too large for this version; its file is preserved.")}
        let data=try Data(contentsOf:url)
        // Read the envelope before decoding its version-specific payload: a newer
        // payload need not have the fields understood by this reader.
        if let envelope=try JSONSerialization.jsonObject(with:data) as? [String:Any],let version=envelope["schemaVersion"] as? Int,version>1 {throw CheckmateError.unavailable("This review requires a newer Checkmate version; its file is preserved.")}
        var saved=try JSONDecoder().decode(SavedReview.self,from:data)
        guard saved.schemaVersion<=1 else{throw CheckmateError.unavailable("This review requires a newer Checkmate version; its file is preserved.")}
        guard saved.schemaVersion==1,saved.document.id==id,saved.document.nodes.indices.contains(saved.cursor) else{throw CheckmateError.invalid("Invalid review version or cursor.")}
        // A re-read tree must still hold the cursor and every idea at the same positions, found by their recorded moves
        // (node numbers can differ between readers); otherwise the file stays preserved, untouched.
        let stored=saved.document,document=try readable(stored),rederived=document != stored
        if rederived{
            guard let cursor=Self.node(saved.cursor,of:stored,in:document) else{throw CheckmateError.invalid("Invalid review version or cursor.")}
            let branches=try saved.branches.map{branch->ReviewBranch in guard let root=Self.node(branch.root,of:stored,in:document) else{throw CheckmateError.invalid("Invalid saved branches.")};return branch.rooted(at:root)}
            saved=SavedReview(schemaVersion:1,document:document,cursor:cursor,branches:branches,updatedAt:saved.updatedAt)
        }
        // A re-read record is not yet on disk in its new numbering: the next save rewrites it whole, never only its cursor.
        try validateBranches(saved.branches,document:saved.document);stamps[id]=stamp(id);branchCache[id]=rederived ? nil:saved.branches;persisted[id]=rederived ? nil:saved.document;preserved[id]=nil;hashes[id]=saved.document.contentHash
        let cursorFile=cursorURL(id)
        if let size=(try? cursorFile.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=4096,let data=try? Data(contentsOf:cursorFile),let metadata=try? JSONDecoder().decode(Cursor.self,from:data),metadata.schemaVersion==1,metadata.updatedAt>=saved.updatedAt,let cursor=rederived ? Self.node(metadata.cursor,of:stored,in:document):(stored.nodes.indices.contains(metadata.cursor) ? metadata.cursor:nil){saved.cursor=cursor;saved.updatedAt=metadata.updatedAt}
        return saved
    }
    /// The node of `target` reached by the moves that reach `node` in `source` (the same move twice among siblings is
    /// told apart by its order), or nil when `target` does not hold that position. The moves alone are not enough: a
    /// re-read start position can differ, so the board, side to move and castling rights must match too (the en
    /// passant field is not compared, since readers differ in when they write it).
    private static func node(_ node:Int,of source:GameDocument,in target:GameDocument)->Int? {
        guard source.nodes.indices.contains(node) else{return nil}
        var steps:[(uci:String,rank:Int)]=[],cursor=node
        while let parent=source.nodes[cursor].parent{guard steps.count<source.nodes.count,let uci=source.nodes[cursor].uci,source.nodes.indices.contains(parent) else{return nil};let siblings=source.nodes[parent].children.filter{source.nodes.indices.contains($0) && source.nodes[$0].uci==uci};guard let rank=siblings.firstIndex(of:cursor) else{return nil};steps.append((uci,rank));cursor=parent}
        var found=0
        for step in steps.reversed(){let matches=target.nodes[found].children.filter{target.nodes.indices.contains($0) && target.nodes[$0].uci==step.uci};guard step.rank<matches.count else{return nil};found=matches[step.rank]}
        func position(_ fen:String)->String {fen.split(separator:" ").prefix(3).joined(separator:" ")}
        return position(target.nodes[found].afterFEN)==position(source.nodes[node].afterFEN) ? found:nil
    }
    public func list()throws -> [ReviewIndexEntry] {
        lock.lock();defer{lock.unlock()};try prepare()
        let documentIDs=Set(try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.compactMap{UUID(uuidString:$0.deletingPathExtension().lastPathComponent)})
        preserved=preserved.filter{documentIDs.contains($0.key) && $0.value==stamp($0.key)}
        let readableIDs=documentIDs.subtracting(preserved.keys)
        if let index=index,Set(index.map(\.id))==readableIDs,index.allSatisfy({stamps[$0.id]==stamp($0.id)}){return index}
        if index==nil {
            let file=directory.appendingPathComponent("index.json")
            if let size=(try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=ReviewPolicy.maximumIndexBytes,let data=try? Data(contentsOf:file),let saved=try? JSONDecoder().decode(Index.self,from:data),saved.schemaVersion==1,saved.entries.count<=ReviewPolicy.maximumSavedRecords,Set(saved.entries.map(\.id)).count==saved.entries.count,Set(saved.entries.map(\.id))==readableIDs,saved.entries.allSatisfy({saved.stamps[$0.id.uuidString]==stamp($0.id)}){index=saved.entries;stamps=Dictionary(uniqueKeysWithValues:saved.entries.map{($0.id,stamp($0.id))});for entry in saved.entries{if let hash=saved.hashes?[entry.id.uuidString]{hashes[entry.id]=hash}};return saved.entries}
        }
        // Directory scan is also recovery for an interrupted index write. It occurs once per store.
        var entries:[ReviewIndexEntry]=[]
        for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where url.pathExtension=="json" {
            guard let id=UUID(uuidString:url.deletingPathExtension().lastPathComponent) else{continue}
            do{let saved=try load(id);entries.append(ReviewIndexEntry(id:id,title:saved.document.title,result:saved.document.result,updatedAt:saved.updatedAt))}
            catch let error as CocoaError where [.fileReadNoPermission,.fileReadUnknown,.fileReadNoSuchFile].contains(error.code){throw error}
            catch let error as CheckmateError{if case .unavailable=error{if futureSchema(url){preserved[id]=stamp(id);continue};throw error};try quarantine(url,id:id)}
            catch{try quarantine(url,id:id)}
        }
        guard entries.count<=ReviewPolicy.maximumSavedRecords else{throw CheckmateError.invalid("Review library record limit exceeded.")}
        index=entries.sorted{$0.updatedAt>$1.updatedAt};try writeIndex();return index!
    }
    private func quarantine(_ url:URL,id:UUID)throws {let quarantine=directory.appendingPathComponent("Quarantine");try FileManager.default.createDirectory(at:quarantine,withIntermediateDirectories:true);try FileManager.default.moveItem(at:url,to:quarantine.appendingPathComponent(UUID().uuidString+"-"+url.lastPathComponent));validated[id]=nil;persisted[id]=nil;hashes[id]=nil;quarantinedSinceTaken+=1}
    private func writeIndex()throws {guard !futureSchema(directory.appendingPathComponent("index.json")) else{return};let entries=index ?? [];let data=try JSONEncoder().encode(Index(schemaVersion:1,entries:entries,stamps:Dictionary(uniqueKeysWithValues:entries.map{($0.id.uuidString,stamp($0.id))}),hashes:Dictionary(uniqueKeysWithValues:entries.compactMap{entry in hashes[entry.id].map{(entry.id.uuidString,$0)}})));try atomicWriter(data,directory.appendingPathComponent("index.json"))}
    /// The saved record whose original text has this hash, so the same game opened again (for example by an agent)
    /// reuses its record instead of filling the library with copies. Records indexed before hashes were kept are
    /// found once they have been loaded or saved again.
    public func savedReview(contentHash:String)throws -> UUID? {lock.lock();defer{lock.unlock()};return try list().first{hashes[$0.id]==contentHash}?.id}
    /// Unreadable records moved to Quarantine since the last call, so the app can tell the learner once.
    public func takeQuarantinedCount()->Int {lock.lock();defer{lock.unlock()};let count=quarantinedSinceTaken;quarantinedSinceTaken=0;return count}
    public func export(_ id:UUID)throws -> Data {try load(id).document.original}
    public func delete(_ id:UUID)throws {
        lock.lock();defer{lock.unlock()};_ = try list()
        guard !futureSchema(documentURL(id)) else{throw CheckmateError.unavailable("This review requires a newer Checkmate version; its file is preserved.")}
        let files=FileManager.default,previousIndex=index
        let sources=[documentURL(id),cursorURL(id)]
        var moved:[(URL,URL)]=[]
        do {
            for source in sources where files.fileExists(atPath:source.path) {
                let backup=directory.appendingPathComponent(".delete-"+UUID().uuidString)
                try files.moveItem(at:source,to:backup);moved.append((source,backup))
            }
            index?.removeAll{$0.id==id};try writeIndex()
        } catch {
            index=previousIndex
            for (source,backup) in moved.reversed(){try files.moveItem(at:backup,to:source)}
            throw error
        }
        validated[id]=nil;persisted[id]=nil;branchCache[id]=nil;stamps[id]=nil;hashes[id]=nil
        for (_,backup) in moved{try? files.removeItem(at:backup)}
    }
}

/// One serial writer orders background autosaves and synchronous close/quit flushes.
public final class ReviewSaveCoordinator {
    private struct Request {let document:GameDocument,cursor:Int,branches:[ReviewBranch],completion:(Result<[ReviewIndexEntry],Error>)->Void}
    private let queue=DispatchQueue(label:"checkmate.review-save"),lock=NSLock()
    private let store:ReviewStore
    /// The latest unsaved request per record: a save of one review never replaces another review's queued save.
    private var latest:[UUID:Request]=[:],draining=false
    private var deleted:Set<UUID>=[]
    public init(store:ReviewStore){self.store=store}
    public func save(_ document:GameDocument,cursor:Int,branches:[ReviewBranch],completion:@escaping(Result<[ReviewIndexEntry],Error>)->Void){
        lock.lock();guard !deleted.contains(document.id) else{lock.unlock();completion(.failure(CheckmateError.cancelled));return};latest[document.id]=Request(document:document,cursor:cursor,branches:branches,completion:completion);let start = !draining;draining=true;lock.unlock()
        guard start else{return};queue.async{while true{self.lock.lock();guard let id=self.latest.keys.first,let request=self.latest.removeValue(forKey:id) else{self.draining=false;self.lock.unlock();return};self.lock.unlock()
            do{try self.store.save(request.document,cursor:request.cursor,branches:request.branches);request.completion(.success(try self.store.list()))}catch{request.completion(.failure(error))}
        }}
    }
    private final class FlushResult {var value:Result<[ReviewIndexEntry],Error>?}
    public func flush(_ document:GameDocument,cursor:Int,branches:[ReviewBranch])throws->[ReviewIndexEntry]{
        lock.lock();latest[document.id]=nil;lock.unlock()
        let finished=DispatchSemaphore(value:0),result=FlushResult()
        // async plus acknowledgement keeps validation and disk I/O off the main
        // thread even when close/termination must wait for durable completion.
        queue.async{do{self.lock.lock();let blocked=self.deleted.contains(document.id);self.lock.unlock();guard !blocked else{throw CheckmateError.cancelled};try self.store.save(document,cursor:cursor,branches:branches);result.value = .success(try self.store.list())}catch{result.value = .failure(error)};finished.signal()}
        finished.wait();return try result.value!.get()
    }
    /// Order deletion after any in-flight save and reject late autosaves for this record.
    public func delete(_ id:UUID)throws->[ReviewIndexEntry]{
        lock.lock();deleted.insert(id);latest[id]=nil;lock.unlock()
        do{return try queue.sync{try store.delete(id);return try store.list()}}
        catch{lock.lock();deleted.remove(id);lock.unlock();throw error}
    }

}
