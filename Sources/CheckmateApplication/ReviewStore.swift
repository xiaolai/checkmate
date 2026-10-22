import CheckmateAssets
import CheckmateDomain
import CheckmateSupport
import Foundation
/// `learnerSide` ("w" or "b") is the learner's own side when the review is of a game they played, so it reopens from
/// that side; saves written before it existed have none and open from White's. `name` is the learner's own name for the
/// review (R-11), absent until they rename it.
public struct SavedReview:Codable {public let schemaVersion:Int,document:GameDocument;public var cursor:Int,branches:[ReviewBranch],updatedAt:Date;public var learnerSide:String?=nil;public var name:String?=nil}
/// `title` is the learner's name for the review when it has one (`name`), else its game's title. The game's players,
/// event and date (known tags only, bounded) let the library search and sort saved reviews without opening them.
public struct ReviewIndexEntry:Codable,Identifiable,Equatable {
    public let id:UUID,title:String,result:String,updatedAt:Date;public var name:String?=nil,white:String?=nil,black:String?=nil,event:String?=nil,date:String?=nil
    static func of(_ document:GameDocument,name:String?,updatedAt:Date)->ReviewIndexEntry {
        func known(_ tag:String)->String? {guard let value=document.header(tag)?.trimmingCharacters(in:.whitespacesAndNewlines),value.contains(where:{$0 != "?" && $0 != "."}) else{return nil};return PGNImporter.bounded(value,scalars:GameCollectionStore.maximumTag)}
        return ReviewIndexEntry(id:document.id,title:name ?? document.title,result:document.result,updatedAt:updatedAt,name:name,white:known("White"),black:known("Black"),event:known("Event"),date:known("Date"))
    }
    /// A name as the learner may give it: control characters become spaces, the ends are trimmed and the length is
    /// bounded like a title; nothing left means no name.
    public static func cleanName(_ text:String?)->String? {
        guard let text else{return nil}
        let spaced=String(String.UnicodeScalarView(text.unicodeScalars.map{CharacterSet.controlCharacters.contains($0) ? " ":$0})).trimmingCharacters(in:.whitespacesAndNewlines)
        return spaced.isEmpty ? nil:String(String.UnicodeScalarView(spaced.unicodeScalars.prefix(ReviewPolicy.maximumTitleScalars)))
    }
}
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
    /// The learner's side each record was last written or read with: a changed side rewrites the record.
    private var sides:[UUID:String]=[:]
    /// Content hash of each saved record's original text, kept in the index so a repeated open can find its record.
    private var hashes:[UUID:String]=[:]
    private var quarantinedSinceTaken=0
    private struct Cursor:Codable {let schemaVersion:Int,cursor:Int,updatedAt:Date}
    /// `hashes` is absent from indexes written before it existed; readers that predate it ignore it. `titleRule` names
    /// the `GameDocument.title` rule its titles were made by: an index from another rule (or none) is rebuilt once.
    private struct Index:Codable {let schemaVersion:Int,entries:[ReviewIndexEntry],stamps:[String:String],hashes:[String:String]?,titleRule:Int?}
    /// 1: the players, then the event. 2: as 1, and each entry also holds the learner's name for the review and its
    /// game's players, event and date.
    private static let titleRule=2
    /// A deleted review waits in `Trash/<id>/` this long, so its deletion can be undone, unless the library needs room.
    static let trashRetention:TimeInterval=30*24*3600
    private var trashChecked=false
    /// What the store knows about its folder, kept by its own changes so that the hot path never looks at every review
    /// (R-28). The cost model, for a library of n reviews:
    /// - A cursor save and `list()` stat a fixed number of files. `list()` trusts its index while the folder's
    ///   modification date is the one the store last saw; a cursor save stats the folder, its Quarantine and the files it
    ///   writes, and moves the running byte total by what they gained or lost. Each of the store's own changes also reads
    ///   the folder's names (no stats) to confirm that nothing else was added or removed while it ran.
    /// - A full save is O(n) stats: before its quota check it re-stats every file the store knows (the Quarantine's too), because the quota is
    ///   a safety limit that must hold even against a file edited in place by something else, which changes neither
    ///   folder's date. Full saves come from deliberate actions, so the cost is paid rarely.
    /// - `list()` re-stats every review on first load and whenever the folder's date changes (a file added or removed
    ///   behind the store's back).
    /// - On a volume whose dates may be too coarse to show a change (`preciseDates`), no folder date is trusted: `list()`
    ///   re-stats every review and every save measures the library.
    /// So a review document edited in place by something else, while the folder's date stays put, is not seen by
    /// `list()` until the folder changes or the store loads again; a full save still measures it for the quota.
    private var usedBytes:Int?,usedDates:[Double]?,ownStamps:[String:String]=[:],listedDate:Double?
    /// `measurements` counts full walks of the library, and `looked` every file or folder that the byte total and the
    /// review list stat; tests read both.
    private(set) var measurements=0,looked=0
    /// Internal test seam: runs between the store's last look at the folder and its own change, where a change by
    /// another program would land.
    var beforeChange:(()->Void)?
    /// Whether the volume holding a folder keeps modification dates fine enough to show every change (APFS keeps
    /// nanoseconds). On any other volume two changes within one tick can leave a folder's date as it was, so the store
    /// trusts no folder date there: the list checks each review and the byte total is measured on every save. Internal
    /// so tests can model a coarse volume.
    var preciseDates:(URL)->Bool={(try? $0.resourceValues(forKeys:[.volumeTypeNameKey]))?.volumeTypeName?.lowercased()=="apfs"}
    /// Each Trash folder's size, by its modification date, so a save does not reread every deleted review.
    private var trashSizes:[String:(stamp:Double,bytes:Int)]=[:]
    private func modified(_ url:URL)throws -> Double {FileManager.default.fileExists(atPath:url.path) ? ((try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0):-1}
    /// The modification dates of the folder and its Quarantine, which change when a file is added to or removed from them.
    private func folderDates()throws -> [Double] {looked+=2;return [try modified(directory),try modified(directory.appendingPathComponent("Quarantine"))]}
    /// A file's size and modification date, read fresh (a URL's resource values are cached), or "absent".
    private func ownStamp(_ url:URL)->String {
        looked+=1;guard let attributes=try? FileManager.default.attributesOfItem(atPath:url.path) else{return "absent"}
        return "\(attributes[.size] as? Int ?? -1):\((attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
    }
    private func size(_ url:URL)throws -> Int {looked+=1;return FileManager.default.fileExists(atPath:url.path) ? ((try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? Int) ?? 0):0}
    /// The library's size outside the Trash: the running total once every file the store knows still has the size and
    /// date it recorded, or a full walk when the total is unknown or stale.
    func libraryBytes()throws -> Int {
        lock.lock();defer{lock.unlock()}
        if let used=usedBytes,preciseDates(directory),try folderDates()==usedDates,ownStamps.allSatisfy({ownStamp(directory.appendingPathComponent($0.key))==$0.value}){return used}
        measurements+=1;var total=0,stamps:[String:String]=[:],found:Set<String>=[];let enumerator=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])
        while let file=enumerator?.nextObject() as? URL {
            if enumerator?.level==1,file.lastPathComponent==trashURL.lastPathComponent{enumerator?.skipDescendants();continue}
            if enumerator?.level==1{found.insert(file.lastPathComponent)}
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);guard values.isRegularFile==true else{continue}
            // Every file is stamped by its path in the folder, a quarantined one too: grown in place, it changes no
            // folder's date either.
            total+=values.fileSize ?? 0;stamps[file.pathComponents.suffix(enumerator?.level ?? 1).joined(separator:"/")]=ownStamp(file)
        }
        usedBytes=total;usedDates=try folderDates();ownStamps=stamps;names=found;return total
    }
    /// The names in the folder itself, but the Trash, as the store last read them; nil when not read since its last
    /// change it could not account for.
    private var names:Set<String>?
    private func folderNames()throws -> Set<String> {Set(try FileManager.default.contentsOfDirectory(atPath:directory.path)).subtracting([trashURL.lastPathComponent])}
    /// Runs one of the store's own changes to `files` (all in the folder itself) and moves the running total by what
    /// they gained or lost. What the store knew is carried past the change only if it still held at the last look before
    /// it (the folder's dates as recorded), and if afterwards the folder holds exactly the names it held, give or take
    /// `files`, and its Quarantine is as it was: anything else is another program's change, made meanwhile, so the total,
    /// the list's folder date and the names are left unknown, to be read again.
    private func tracking<T>(_ files:[URL],_ change:()throws->T)throws -> T {
        func measured()throws -> Int {try files.reduce(0){$0+(try size($1))}}
        let known=usedBytes != nil && files.allSatisfy{ownStamp($0)==(ownStamps[$0.lastPathComponent] ?? "absent")},before=try known ? measured():0
        let precise=preciseDates(directory),dates=try folderDates(),listed=precise && listedDate != nil && listedDate==dates[0],counted=precise && known && dates==usedDates
        beforeChange?();let result:T;do{result=try change()}catch{usedBytes=nil;listedDate=nil;names=nil;throw error}
        let now=try folderDates(),marks=files.map(ownStamp),found=try folderNames()
        var expected=names;for (file,stamp) in zip(files,marks){if stamp=="absent"{expected?.remove(file.lastPathComponent)}else{expected?.insert(file.lastPathComponent)}}
        let alone=expected==found && now[1]==dates[1];names=alone ? found:nil;listedDate=listed && alone ? now[0]:nil
        if counted,alone,let used=usedBytes{let after=try measured();usedBytes=used-before+after;usedDates=now;for (file,stamp) in zip(files,marks){ownStamps[file.lastPathComponent]=stamp=="absent" ? nil:stamp}}else{usedBytes=nil}
        return result
    }
    private var indexURL:URL {directory.appendingPathComponent("index.json")}
    /// Called with each deleted review that leaves the Trash for good (expired or making room), on the thread that
    /// purged it, so what was kept for its Undo (its engine analysis) goes with it.
    public var onPurge:((UUID)->Void)?
    /// Removes a Trash folder for good and names its review.
    private func purge(_ folder:URL)throws {try FileManager.default.removeItem(at:folder);if let id=UUID(uuidString:folder.lastPathComponent){onPurge?(id)}}
    private var trashURL:URL {directory.appendingPathComponent("Trash")}
    private func trashURL(_ id:UUID)->URL {trashURL.appendingPathComponent(id.uuidString)}
    /// The Trash's folders, oldest deletion first, with their sizes.
    private func trashed()throws -> [(url:URL,deleted:Date,bytes:Int)] {
        let files=FileManager.default;guard files.fileExists(atPath:trashURL.path) else{return []}
        let folders=try files.contentsOfDirectory(at:trashURL,includingPropertiesForKeys:[.creationDateKey]);trashSizes=trashSizes.filter{path,_ in folders.contains{$0.path==path}}
        return try folders.map{folder in
            let stamp=try modified(folder),deleted=try folder.resourceValues(forKeys:[.creationDateKey]).creationDate ?? .distantPast
            if let cached=trashSizes[folder.path],cached.stamp==stamp{return (folder,deleted,cached.bytes)}
            var bytes=0;let enumerator=files.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])
            while let file=enumerator?.nextObject() as? URL {let values=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);if values.isRegularFile==true{bytes+=values.fileSize ?? 0}}
            trashSizes[folder.path]=(stamp,bytes);return (folder,deleted,bytes)
        }.sorted{$0.deleted<$1.deleted}
    }
    private func futureSchema(_ url:URL)->Bool {
        let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]);if (values?.fileSize ?? 0)>ReviewPolicy.maximumSavedBytes{return true};let identity="\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached=schemaCache[url.path],cached.stamp==identity{return cached.future}
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=ReviewPolicy.maximumSavedBytes,let data=try? Data(contentsOf:url),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let version=object["schemaVersion"] as? Int else{return false}
        schemaCache[url.path]=(identity,version>1);return version>1
    }
    private func cursorURL(_ id:UUID)->URL {directory.appendingPathComponent(id.uuidString+".cursor.json")}
    private func saveCursor(_ id:UUID,cursor:Int,date:Date)throws {guard !futureSchema(cursorURL(id)) else{return};try atomicWriter(JSONEncoder().encode(Cursor(schemaVersion:1,cursor:cursor,updatedAt:date)),cursorURL(id))}
    private func stamp(_ id:UUID)->String {looked+=1;let values=try? documentURL(id).resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]);return "\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"}
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
        guard branches.count<=ReviewPolicy.maximumBranches,Set(branches.map(\.id)).count==branches.count else{throw CheckmateError.invalid(String(localized:"The saved imagined lines could not be read.",bundle:.checkmate))}
        for branch in branches{let rules=try document.snapshotRules(at:branch.root);guard branch.moves.count<=ReviewPolicy.maximumBranchPlies else{throw CheckmateError.invalid(String(localized:"A saved imagined line is too long.",bundle:.checkmate))};for move in branch.moves{try rules.move(uci:move)}}
    }
    public func save(_ document:GameDocument,cursor:Int,branches:[ReviewBranch],learnerSide:String?=nil)throws {
        lock.lock();defer{lock.unlock()};try write(document,cursor:cursor,branches:branches,learnerSide:learnerSide,name:nil,date:nil)
    }
    /// Gives a saved review the learner's own name, or with nil or only spaces gives it back its game's title. The
    /// review keeps its place in the recent list.
    public func rename(_ id:UUID,to name:String?)throws {
        lock.lock();defer{lock.unlock()}
        guard let entry=try list().first(where:{$0.id==id}) else{throw CheckmateError.invalid(String(localized:"This review is no longer in the library.",bundle:.checkmate))}
        let saved=try load(id);try write(saved.document,cursor:saved.cursor,branches:saved.branches,learnerSide:saved.learnerSide,name:.some(ReviewIndexEntry.cleanName(name)),date:entry.updatedAt)
    }
    /// `name` nil keeps the record's current name; `date` nil stamps the write with now.
    private func write(_ document:GameDocument,cursor:Int,branches:[ReviewBranch],learnerSide:String?,name requested:String??,date fixed:Date?)throws {
        try prepare();guard !futureSchema(documentURL(document.id)) else{throw CheckmateError.unavailable(String(localized:"This review requires a newer Checkmate version; its file is preserved.",bundle:.checkmate))};try validate(document)
        guard document.nodes.indices.contains(cursor) else{throw CheckmateError.invalid(String(localized:"Invalid saved review cursor.",bundle:.checkmate))}
        var entries=try list()
        guard learnerSide.map({["w","b"].contains($0)}) ?? true else{throw CheckmateError.invalid(String(localized:"Invalid saved review side.",bundle:.checkmate))}
        let current=entries.first{$0.id==document.id},name=requested ?? current?.name
        if branchCache[document.id]==branches,sides[document.id]==learnerSide,let current,current.name==name,persisted[document.id]==document,!futureSchema(cursorURL(document.id)) {
            let date=fixed ?? Date()
            try tracking([cursorURL(document.id),indexURL]){try saveCursor(document.id,cursor:cursor,date:date)
                entries.removeAll{$0.id==document.id};entries.append(.of(document,name:name,updatedAt:date));index=entries.sorted{$0.updatedAt>$1.updatedAt};try writeIndex()};return
        }
        try validateBranches(branches,document:document)
        guard current != nil || entries.count<ReviewPolicy.maximumSavedRecords else{throw CheckmateError.invalid(String(localized:"Review library record limit reached.",bundle:.checkmate))}
        let saved=SavedReview(schemaVersion:1,document:document,cursor:cursor,branches:branches,updatedAt:fixed ?? Date(),learnerSide:learnerSide,name:name),data=try JSONEncoder().encode(saved)
        guard data.count<=ReviewPolicy.maximumSavedBytes else{throw CheckmateError.invalid(String(localized:"Saved review exceeds storage limit.",bundle:.checkmate))}
        // The record being replaced does not count against its own new version.
        var total=try libraryBytes()-size(documentURL(document.id))
        // The Trash counts toward the library, but gives way, oldest deletion first, before a save is refused.
        var trash=try trashed()
        while total+trash.reduce(0,{$0+$1.bytes})+data.count>ReviewPolicy.maximumLibraryBytes,let oldest=trash.first {try purge(oldest.url);trash.removeFirst();NativeLog.storage.info("Removed a deleted review to make room in the library")}
        total+=trash.reduce(0){$0+$1.bytes}
        guard total+data.count<=ReviewPolicy.maximumLibraryBytes else{throw CheckmateError.invalid(String(localized:"Review library storage limit reached; export or delete older reviews.",bundle:.checkmate))}
        let url=documentURL(document.id)
        try tracking([url,cursorURL(document.id),indexURL]){
            try atomicWriter(data,url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            guard try Data(contentsOf:url)==data else{throw CheckmateError.unavailable(String(localized:"Review read-back failed.",bundle:.checkmate))}
            persisted[document.id]=document;hashes[document.id]=document.contentHash;sides[document.id]=learnerSide
            entries.removeAll{$0.id==document.id};entries.append(.of(document,name:name,updatedAt:saved.updatedAt));index=entries.sorted{$0.updatedAt>$1.updatedAt};stamps[document.id]=stamp(document.id);branchCache[document.id]=branches;try saveCursor(document.id,cursor:cursor,date:saved.updatedAt);try writeIndex()
        }
    }
    public func load(_ id:UUID)throws -> SavedReview {
        lock.lock();defer{lock.unlock()};let url=documentURL(id),size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size<=ReviewPolicy.maximumSavedBytes else{throw CheckmateError.unavailable(String(localized:"This review is too large for this version; its file is preserved.",bundle:.checkmate))}
        let data=try Data(contentsOf:url)
        // Read the envelope before decoding its version-specific payload: a newer
        // payload need not have the fields understood by this reader.
        if let envelope=try JSONSerialization.jsonObject(with:data) as? [String:Any],let version=envelope["schemaVersion"] as? Int,version>1 {throw CheckmateError.unavailable(String(localized:"This review requires a newer Checkmate version; its file is preserved.",bundle:.checkmate))}
        var saved=try JSONDecoder().decode(SavedReview.self,from:data)
        // A side this reader cannot hold is ignored, as if the record had none.
        if let side=saved.learnerSide,!["w","b"].contains(side){saved.learnerSide=nil}
        saved.name=ReviewIndexEntry.cleanName(saved.name)
        guard saved.schemaVersion<=1 else{throw CheckmateError.unavailable(String(localized:"This review requires a newer Checkmate version; its file is preserved.",bundle:.checkmate))}
        guard saved.schemaVersion==1,saved.document.id==id,saved.document.nodes.indices.contains(saved.cursor) else{throw CheckmateError.invalid(String(localized:"This saved review could not be read.",bundle:.checkmate))}
        // A re-read tree must still hold the cursor and every idea at the same positions, found by their recorded moves
        // (node numbers can differ between readers); otherwise the file stays preserved, untouched.
        let stored=saved.document,document=try readable(stored),rederived=document != stored
        if rederived{
            guard let cursor=Self.node(saved.cursor,of:stored,in:document) else{throw CheckmateError.invalid(String(localized:"This saved review could not be read.",bundle:.checkmate))}
            let branches=try saved.branches.map{branch->ReviewBranch in guard let root=Self.node(branch.root,of:stored,in:document) else{throw CheckmateError.invalid(String(localized:"The saved imagined lines could not be read.",bundle:.checkmate))};return branch.rooted(at:root)}
            saved=SavedReview(schemaVersion:1,document:document,cursor:cursor,branches:branches,updatedAt:saved.updatedAt,learnerSide:saved.learnerSide,name:saved.name)
        }
        // A re-read record is not yet on disk in its new numbering: the next save rewrites it whole, never only its cursor.
        try validateBranches(saved.branches,document:saved.document);let fresh=stamp(id),changed=stamps[id] != fresh;stamps[id]=fresh;branchCache[id]=rederived ? nil:saved.branches;persisted[id]=rederived ? nil:saved.document;preserved[id]=nil;hashes[id]=saved.document.contentHash;sides[id]=saved.learnerSide
        let cursorFile=cursorURL(id)
        if let size=(try? cursorFile.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=4096,let data=try? Data(contentsOf:cursorFile),let metadata=try? JSONDecoder().decode(Cursor.self,from:data),metadata.schemaVersion==1,metadata.updatedAt>=saved.updatedAt,let cursor=rederived ? Self.node(metadata.cursor,of:stored,in:document):(stored.nodes.indices.contains(metadata.cursor) ? metadata.cursor:nil){saved.cursor=cursor;saved.updatedAt=metadata.updatedAt}
        // A record that changed since the store last read it (rewritten in place by something else) has its list entry
        // made again from what was read, so neither the list nor the next saved index pairs the new stamp with the old entry.
        if changed,let at=index?.firstIndex(where:{$0.id==id}){index?[at]=ReviewIndexEntry.of(saved.document,name:saved.name,updatedAt:saved.updatedAt);index!.sort{$0.updatedAt>$1.updatedAt}}
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
        // Once per store: reviews deleted more than `trashRetention` ago leave the Trash. A folder that cannot be removed
        // is logged and tried again next launch; it never keeps the library from opening.
        if !trashChecked{trashChecked=true;let cutoff=Date().addingTimeInterval(-Self.trashRetention)
            do{for folder in try trashed() where folder.deleted<cutoff{try purge(folder.url);NativeLog.storage.info("Removed a review deleted over 30 days ago")}}
            catch{NativeLog.storage.error("The review Trash could not be emptied: \(String(describing:error),privacy:.public)")}
        }
        // The folder's date is unchanged since the store last confirmed its index: no review was added or removed.
        looked+=1;let date=try modified(directory)
        if let index,listedDate==date,preciseDates(directory){return index}
        let listing=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil);names=Set(listing.map(\.lastPathComponent)).subtracting([trashURL.lastPathComponent])
        let documentIDs=Set(listing.filter{$0.pathExtension=="json"}.compactMap{UUID(uuidString:$0.deletingPathExtension().lastPathComponent)})
        preserved=preserved.filter{documentIDs.contains($0.key) && $0.value==stamp($0.key)}
        let readableIDs=documentIDs.subtracting(preserved.keys)
        if let index=index,Set(index.map(\.id))==readableIDs,index.allSatisfy({stamps[$0.id]==stamp($0.id)}){listedDate=date;return index}
        if index==nil {
            let file=directory.appendingPathComponent("index.json")
            if let size=(try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=ReviewPolicy.maximumIndexBytes,let data=try? Data(contentsOf:file),let saved=try? JSONDecoder().decode(Index.self,from:data),saved.schemaVersion==1,saved.titleRule==Self.titleRule,saved.entries.count<=ReviewPolicy.maximumSavedRecords,Set(saved.entries.map(\.id)).count==saved.entries.count,Set(saved.entries.map(\.id))==readableIDs,saved.entries.allSatisfy({saved.stamps[$0.id.uuidString]==stamp($0.id)}){index=saved.entries;stamps=Dictionary(uniqueKeysWithValues:saved.entries.map{($0.id,saved.stamps[$0.id.uuidString] ?? stamp($0.id))});for entry in saved.entries{if let hash=saved.hashes?[entry.id.uuidString]{hashes[entry.id]=hash}};listedDate=date;return saved.entries}
        }
        // Directory scan is also recovery for an interrupted index write. It occurs once per store.
        usedBytes=nil;var entries:[ReviewIndexEntry]=[]
        for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where url.pathExtension=="json" {
            guard let id=UUID(uuidString:url.deletingPathExtension().lastPathComponent) else{continue}
            do{let saved=try load(id);entries.append(.of(saved.document,name:saved.name,updatedAt:saved.updatedAt))}
            catch let error as CocoaError where [.fileReadNoPermission,.fileReadUnknown,.fileReadNoSuchFile].contains(error.code){throw error}
            catch let error as CheckmateError{if case .unavailable=error{if futureSchema(url){preserved[id]=stamp(id);continue};throw error};try quarantine(url,id:id)}
            catch{try quarantine(url,id:id)}
        }
        guard entries.count<=ReviewPolicy.maximumSavedRecords else{throw CheckmateError.invalid(String(localized:"Review library record limit exceeded.",bundle:.checkmate))}
        // The date read before the scan: the scan's own quarantines and index write move it, so the next call checks each
        // review once more rather than trust a date that could also hide a change made during the scan. The names read
        // before it are stale too.
        index=entries.sorted{$0.updatedAt>$1.updatedAt};try writeIndex();listedDate=date;names=nil;return index!
    }
    private func quarantine(_ url:URL,id:UUID)throws {let quarantine=directory.appendingPathComponent("Quarantine");try FileManager.default.createDirectory(at:quarantine,withIntermediateDirectories:true);try FileManager.default.moveItem(at:url,to:quarantine.appendingPathComponent(UUID().uuidString+"-"+url.lastPathComponent));validated[id]=nil;persisted[id]=nil;hashes[id]=nil;quarantinedSinceTaken+=1;usedBytes=nil;names=nil}
    private func writeIndex()throws {guard !futureSchema(directory.appendingPathComponent("index.json")) else{return};let entries=index ?? [];let data=try JSONEncoder().encode(Index(schemaVersion:1,entries:entries,stamps:Dictionary(uniqueKeysWithValues:entries.map{($0.id.uuidString,stamps[$0.id] ?? stamp($0.id))}),hashes:Dictionary(uniqueKeysWithValues:entries.compactMap{entry in hashes[entry.id].map{(entry.id.uuidString,$0)}}),titleRule:Self.titleRule));try atomicWriter(data,indexURL)}
    /// The saved record whose original text has this hash, so the same game opened again (for example by an agent)
    /// reuses its record instead of filling the library with copies. Records indexed before hashes were kept are
    /// found once they have been loaded or saved again.
    public func savedReview(contentHash:String)throws -> UUID? {lock.lock();defer{lock.unlock()};return try list().first{hashes[$0.id]==contentHash}?.id}
    /// Unreadable records moved to Quarantine since the last call, so the app can tell the learner once.
    public func takeQuarantinedCount()->Int {lock.lock();defer{lock.unlock()};let count=quarantinedSinceTaken;quarantinedSinceTaken=0;return count}
    public func export(_ id:UUID)throws -> Data {try load(id).document.original}
    public func delete(_ id:UUID)throws {
        lock.lock();defer{lock.unlock()};_ = try list()
        guard !futureSchema(documentURL(id)) else{throw CheckmateError.unavailable(String(localized:"This review requires a newer Checkmate version; its file is preserved.",bundle:.checkmate))}
        // The record and its cursor move to `Trash/<id>/`, replacing an earlier deletion of the same record; the folder's
        // creation date is the deletion date.
        let files=FileManager.default,previousIndex=index,folder=trashURL(id),sources=[documentURL(id),cursorURL(id)].filter{files.fileExists(atPath:$0.path)}
        var moved:[(URL,URL)]=[]
        do {
            // The Trash is made inside the tracked change: making it changes the library folder's date, which would
            // otherwise read as a change by something else and cost a full measurement.
            try tracking([documentURL(id),cursorURL(id),indexURL]){
                if !sources.isEmpty{if files.fileExists(atPath:folder.path){try files.removeItem(at:folder)};try files.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
                for source in sources {
                    let target=folder.appendingPathComponent(source.lastPathComponent)
                    try files.moveItem(at:source,to:target);moved.append((source,target))
                }
                index?.removeAll{$0.id==id};try writeIndex()
            }
        } catch {
            index=previousIndex
            for (source,target) in moved.reversed(){try files.moveItem(at:target,to:source)}
            if !sources.isEmpty,files.fileExists(atPath:folder.path){try files.removeItem(at:folder)}
            throw error
        }
        validated[id]=nil;persisted[id]=nil;branchCache[id]=nil;stamps[id]=nil;hashes[id]=nil
    }
    /// Puts a deleted review back from the Trash (Undo of its deletion), as it was when deleted.
    public func restore(_ id:UUID)throws {
        lock.lock();defer{lock.unlock()};var entries=try list()
        let files=FileManager.default,folder=trashURL(id),document=folder.appendingPathComponent(documentURL(id).lastPathComponent)
        guard files.fileExists(atPath:document.path) else{throw CheckmateError.invalid(String(localized:"This review is no longer in the Trash.",bundle:.checkmate))}
        guard !files.fileExists(atPath:documentURL(id).path),!entries.contains(where:{$0.id==id}) else{throw CheckmateError.invalid(String(localized:"This review is already in the library.",bundle:.checkmate))}
        guard entries.count<ReviewPolicy.maximumSavedRecords else{throw CheckmateError.invalid(String(localized:"Review library record limit reached.",bundle:.checkmate))}
        var moved:[(URL,URL)]=[]
        do {
            try tracking([documentURL(id),cursorURL(id),indexURL]){
                for target in [documentURL(id),cursorURL(id)] {let source=folder.appendingPathComponent(target.lastPathComponent);if files.fileExists(atPath:source.path){try files.moveItem(at:source,to:target);moved.append((source,target))}}
                let saved=try load(id)
                entries.append(.of(saved.document,name:saved.name,updatedAt:saved.updatedAt));index=entries.sorted{$0.updatedAt>$1.updatedAt};try writeIndex()
            }
        } catch {
            index=entries.filter{$0.id != id};validated[id]=nil;persisted[id]=nil;branchCache[id]=nil;stamps[id]=nil;hashes[id]=nil
            for (source,target) in moved.reversed(){try files.moveItem(at:target,to:source)}
            throw error
        }
        try files.removeItem(at:folder)
    }
}

/// One serial writer orders background autosaves and synchronous close/quit flushes.
public final class ReviewSaveCoordinator {
    private struct Request {let document:GameDocument,cursor:Int,branches:[ReviewBranch],learnerSide:String?,completion:(Result<[ReviewIndexEntry],Error>)->Void}
    private let queue=DispatchQueue(label:"checkmate.review-save"),lock=NSLock()
    private let store:ReviewStore
    /// The latest unsaved request per record: a save of one review never replaces another review's queued save.
    private var latest:[UUID:Request]=[:],draining=false
    private var deleted:Set<UUID>=[]
    public init(store:ReviewStore){self.store=store}
    public func save(_ document:GameDocument,cursor:Int,branches:[ReviewBranch],learnerSide:String?=nil,completion:@escaping(Result<[ReviewIndexEntry],Error>)->Void){
        lock.lock();guard !deleted.contains(document.id) else{lock.unlock();completion(.failure(CheckmateError.cancelled));return};latest[document.id]=Request(document:document,cursor:cursor,branches:branches,learnerSide:learnerSide,completion:completion);let start = !draining;draining=true;lock.unlock()
        guard start else{return};queue.async{while true{self.lock.lock();guard let id=self.latest.keys.first,let request=self.latest.removeValue(forKey:id) else{self.draining=false;self.lock.unlock();return};self.lock.unlock()
            do{try self.store.save(request.document,cursor:request.cursor,branches:request.branches,learnerSide:request.learnerSide);request.completion(.success(try self.store.list()))}catch{request.completion(.failure(error))}
        }}
    }
    private final class FlushResult {var value:Result<[ReviewIndexEntry],Error>?}
    public func flush(_ document:GameDocument,cursor:Int,branches:[ReviewBranch],learnerSide:String?=nil)throws->[ReviewIndexEntry]{
        lock.lock();latest[document.id]=nil;lock.unlock()
        let finished=DispatchSemaphore(value:0),result=FlushResult()
        // async plus acknowledgement keeps validation and disk I/O off the main
        // thread even when close/termination must wait for durable completion.
        queue.async{do{self.lock.lock();let blocked=self.deleted.contains(document.id);self.lock.unlock();guard !blocked else{throw CheckmateError.cancelled};try self.store.save(document,cursor:cursor,branches:branches,learnerSide:learnerSide);result.value = .success(try self.store.list())}catch{result.value = .failure(error)};finished.signal()}
        finished.wait();return try result.value!.get()
    }
    /// Order deletion after any in-flight save and reject late autosaves for this record.
    public func delete(_ id:UUID)throws->[ReviewIndexEntry]{
        lock.lock();deleted.insert(id);latest[id]=nil;lock.unlock()
        do{return try queue.sync{try store.delete(id);return try store.list()}}
        catch{lock.lock();deleted.remove(id);lock.unlock();throw error}
    }
    /// Undo of `delete`: the record comes back from the Trash and its saves are accepted again.
    public func restore(_ id:UUID)throws->[ReviewIndexEntry]{
        let entries=try queue.sync{try store.restore(id);return try store.list()}
        lock.lock();deleted.remove(id);lock.unlock();return entries
    }
    /// Renames after any in-flight save of the record, so a late autosave keeps the new name.
    public func rename(_ id:UUID,to name:String?)throws->[ReviewIndexEntry]{try queue.sync{try store.rename(id,to:name);return try store.list()}}

}
