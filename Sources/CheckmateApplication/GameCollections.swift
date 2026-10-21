import CheckmateAssets
import CheckmateDomain
import CheckmateSupport
import Foundation
/// One record of an imported collection: its byte range in the collection file, that range's hash, and the header
/// tags the library lists (untrusted text, bounded; shown verbatim).
public struct CollectionRecord:Codable,Equatable,Sendable {
    public let offset:Int,length:Int,sha256:String,tags:[String:String]
    public func tag(_ name:String)->String? {tags[name]}
}
/// The derived index of a collection file (`Library/<sha256>.index.json`); rebuilt from the file whenever it is missing,
/// unreadable or of an older schema.
public struct CollectionIndex:Codable,Equatable,Sendable,Identifiable {
    public static let schemaVersion=1
    public let schemaVersion:Int,sha256:String,name:String,bytes:Int,importedAt:Date,records:[CollectionRecord],unreadable:Int
    public var id:String {sha256}
    /// The same collection under another name (its stored name file wins over the name its index was built with).
    func named(_ name:String)->CollectionIndex {CollectionIndex(schemaVersion:schemaVersion,sha256:sha256,name:name,bytes:bytes,importedAt:importedAt,records:records,unreadable:unreadable)}
}
/// A collection whose file or index could not be read: shown with its error in its own section.
public struct BrokenCollection:Equatable,Sendable,Identifiable {public let id:String,name:String,error:String;public init(id:String,name:String,error:String){self.id=id;self.name=name;self.error=error}}
/// The learner's imported game collections, in the data directory's own `Library/` folder: separate from `Reviews/`,
/// with its own quota. A collection is stored once per content (`<sha256>.pgn`) with a derived index. Nothing here is a
/// saved review, so MCP never sees a collection; a review saved from one of its games holds its own original bytes.
/// Call from an I/O task.
public final class GameCollectionStore:@unchecked Sendable {
    public static let quotaBytes=256*1024*1024,maximumRecords=20_000
    static let tagNames:Set<String>=["Event","Site","Date","Round","White","Black","Result","ECO","Opening"],maximumTag=200,maximumName=200 // not localized: PGN tag names
    public let directory:URL,quotaBytes:Int
    private let lock=NSLock()
    /// Bumped by each removal of a collection: an import of that content still in flight is cancelled, never revived.
    private var removals:[String:Int]=[:]
    public init(directory:URL,quotaBytes:Int=GameCollectionStore.quotaBytes){self.directory=directory;self.quotaBytes=quotaBytes}
    private func file(_ sha:String)->URL {directory.appendingPathComponent(sha+".pgn")}
    private func indexFile(_ sha:String)->URL {directory.appendingPathComponent(sha+".index.json")}
    /// The collection's display name (`<sha256>.name`, UTF-8), kept apart from its derived index so a rebuilt index
    /// keeps the name it was imported with.
    private func nameFile(_ sha:String)->URL {directory.appendingPathComponent(sha+".name")}
    /// The stored name, or nil when there is none (a collection from an older build) or it cannot be read.
    private func storedName(_ sha:String)->String? {
        guard FileManager.default.fileExists(atPath:nameFile(sha).path) else{return nil}
        do{let data=try Data(contentsOf:nameFile(sha));guard data.count<=4*Self.maximumName,let name=String(data:data,encoding:.utf8),!name.isEmpty else{NativeLog.storage.error("A collection's stored name is unreadable");return nil};return PGNImporter.bounded(name,scalars:Self.maximumName)}
        catch{NativeLog.storage.error("A collection's stored name could not be read: \(String(describing:error),privacy:.public)");return nil}
    }
    /// The name for a collection without a stored one: its most common known Event (ties go to the first seen), else
    /// "Collection".
    static func fallbackName(_ records:[CollectionRecord])->String {
        var counts:[String:Int]=[:],order:[String]=[]
        for event in records.compactMap({$0.tag("Event")?.trimmingCharacters(in:.whitespacesAndNewlines)}) where !event.isEmpty && event != "?" {if counts[event]==nil{order.append(event)};counts[event,default:0]+=1}
        var best:String?;for event in order where counts[event,default:0]>best.map({counts[$0,default:0]}) ?? 0{best=event}
        return best ?? String(localized:"Collection",bundle:.checkmate)
    }
    private static func isDigest(_ text:String)->Bool {text.count==64 && text.allSatisfy{"0123456789abcdef".contains($0)}}
    private func prepare()throws {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    /// Every mutation, and the clean-up of temporary files, holds this store's lock and an advisory `flock` on
    /// `Library/.lock`, so two stores or two processes on one folder never pass the quota together or remove each
    /// other's temporary files.
    private func exclusive<T>(_ body:()throws->T)throws -> T {
        lock.lock();defer{lock.unlock()};try prepare()
        let descriptor=Darwin.open(directory.appendingPathComponent(".lock").path,O_RDWR|O_CREAT|O_CLOEXEC,0o600);guard descriptor>=0 else{throw CheckmateError.invalid(String(localized:"The library could not be locked.",bundle:.checkmate))}
        defer{Darwin.close(descriptor)};guard flock(descriptor,LOCK_EX)==0 else{throw CheckmateError.invalid(String(localized:"The library could not be locked.",bundle:.checkmate))};defer{flock(descriptor,LOCK_UN)}
        return try body()
    }
    /// A rename or removal is durable only once the folder's own entry list is flushed.
    /// Fails the operation if the folder cannot be flushed: success is reported only once the change is on disk.
    private func syncDirectory()throws {
        let descriptor=Darwin.open(directory.path,O_RDONLY|O_CLOEXEC);guard descriptor>=0 else{throw CheckmateError.invalid(String(localized:"The library folder could not be flushed to disk.",bundle:.checkmate))}
        defer{Darwin.close(descriptor)};guard fsync(descriptor)==0 else{throw CheckmateError.invalid(String(localized:"The library folder could not be flushed to disk.",bundle:.checkmate))}
    }
    /// Written to a temporary file, flushed to disk, renamed into place and the folder flushed: after a crash or power
    /// loss the name holds the old complete file or the new complete one, never a partial file.
    private func durableWrite(_ data:Data,to url:URL)throws {
        let temporary=directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw CheckmateError.invalid(String(localized:"The library could not be written.",bundle:.checkmate))}
        do{let handle=try FileHandle(forWritingTo:temporary);defer{try? handle.close()};try handle.write(contentsOf:data);try handle.synchronize()
            guard Darwin.rename(temporary.path,url.path)==0 else{throw CheckmateError.invalid(String(localized:"The library could not be written.",bundle:.checkmate))}}catch{try? FileManager.default.removeItem(at:temporary);throw error}
        try syncDirectory()
    }
    private let removalsLock=NSLock()
    private func removalCount(_ sha:String)->Int {removalsLock.lock();defer{removalsLock.unlock()};return removals[sha] ?? 0}
    /// Bytes used by every collection file and index (temporary and lock files excluded).
    public func usedBytes()->Int {
        ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey])) ?? []).filter{!$0.lastPathComponent.hasPrefix(".")}.reduce(0){$0+(((try? $1.resourceValues(forKeys:[.fileSizeKey]))?.fileSize) ?? 0)}
    }
    static func index(_ data:Data,sha:String,name:String,importedAt:Date,cancelled:@escaping ()->Bool)throws -> CollectionIndex {
        let split=try PGNImporter.splitRecords(data,maximumRecords:maximumRecords,cancelled:cancelled)
        let records=split.records.map{span in
            CollectionRecord(offset:span.offset,length:span.length,sha256:reviewHash(data.subdata(in:span.offset..<span.offset+span.length)),tags:span.tags.filter{tagNames.contains($0.key)}.mapValues{PGNImporter.bounded($0,scalars:maximumTag)})}
        guard !records.isEmpty else{throw CheckmateError.invalid(String(localized:"No games were found in this file.",bundle:.checkmate))}
        return CollectionIndex(schemaVersion:CollectionIndex.schemaVersion,sha256:sha,name:PGNImporter.bounded(name,scalars:maximumName),bytes:data.count,importedAt:importedAt,records:records,unreadable:split.unreadable)
    }
    /// Imports a collection; the same content imported again is stored once and returns the existing index. Without a
    /// name (a record pasted or dropped) it is named after its games' most common event.
    public func importCollection(_ data:Data,name:String?,cancelled:@escaping ()->Bool={false})throws -> CollectionIndex {
        guard data.count<=ReviewPolicy.maximumBytes else{throw CheckmateError.invalid(String(localized:"This file is larger than 16 MiB; split it into smaller files.",bundle:.checkmate))}
        let sha=reviewHash(data),removed=removalCount(sha)
        if let existing=try? readIndex(sha),FileManager.default.fileExists(atPath:file(sha).path){return existing}
        let read=try Self.index(data,sha:sha,name:name ?? String(localized:"Collection",bundle:.checkmate),importedAt:Date(),cancelled:cancelled),index=name==nil ? read.named(PGNImporter.bounded(Self.fallbackName(read.records),scalars:Self.maximumName)):read
        let encoded=try JSONEncoder().encode(index)
        return try exclusive{
            // Removed while it was being read: the import is cancelled and nothing is written.
            guard removalCount(sha)==removed,!cancelled() else{throw CheckmateError.cancelled}
            // Checked again under the lock: another import of the same bytes may have finished meanwhile.
            if let existing=try? readIndex(sha){return existing}
            let stored=FileManager.default.fileExists(atPath:file(sha).path)
            // Only the bytes this import adds are charged: an unreadable index it replaces is subtracted.
            let replaced=[indexFile(sha),nameFile(sha)].reduce(0){$0+(((try? FileManager.default.attributesOfItem(atPath:$1.path))?[.size] as? Int) ?? 0)},label=Data(index.name.utf8)
            guard usedBytes()-replaced+(stored ? 0:data.count)+encoded.count+label.count<=quotaBytes else{throw CheckmateError.invalid(String(localized:"The game library is full (\(quotaBytes/1024/1024) MiB). Remove a collection first.",bundle:.checkmate))}
            do{if !stored{try durableWrite(data,to:file(sha))};try durableWrite(label,to:nameFile(sha));try durableWrite(encoded,to:indexFile(sha))}catch{
                // No half-imported collection is left behind: the file this import created goes with its failed index,
                // including when the file itself was renamed into place but its folder could not be flushed.
                if !stored{try? FileManager.default.removeItem(at:file(sha));try? FileManager.default.removeItem(at:nameFile(sha));try? syncDirectory()};throw error
            }
            return index
        }
    }
    private func readIndex(_ sha:String)throws -> CollectionIndex {
        let index=try JSONDecoder().decode(CollectionIndex.self,from:Data(contentsOf:indexFile(sha)))
        let size=(try FileManager.default.attributesOfItem(atPath:file(sha).path)[.size] as? Int) ?? -1
        guard index.schemaVersion==CollectionIndex.schemaVersion,index.sha256==sha,index.bytes==size,index.records.count<=Self.maximumRecords,
              index.records.allSatisfy({$0.offset>=0 && $0.length>0 && $0.offset<=size && $0.length<=size-$0.offset && Self.isDigest($0.sha256)}) else{throw CheckmateError.invalid(String(localized:"Stale collection index.",bundle:.checkmate))}
        return index
    }
    /// Every collection, oldest import first. Stray temporary files are removed; an index that is missing, unreadable or
    /// of an old schema is rebuilt from its file; a collection that cannot be read is returned as broken, never hidden.
    public func load(cancelled:@escaping ()->Bool={false})throws -> (collections:[CollectionIndex],broken:[BrokenCollection]) {
        guard FileManager.default.fileExists(atPath:directory.path) else{return ([],[])}
        return try exclusive{try loadLocked(cancelled:cancelled)}
    }
    private func loadLocked(cancelled:@escaping ()->Bool)throws -> (collections:[CollectionIndex],broken:[BrokenCollection]) {
        let names=try FileManager.default.contentsOfDirectory(atPath:directory.path)
        for name in names where name.hasPrefix(".") && name.hasSuffix(".tmp"){  // safe: every writer holds the lock
            try? FileManager.default.removeItem(at:directory.appendingPathComponent(name))
        }
        var collections:[CollectionIndex]=[],broken:[BrokenCollection]=[]
        for name in names.sorted() where name.hasSuffix(".pgn") {
            let sha=String(name.dropLast(4));guard Self.isDigest(sha) else{continue}
            let stored=storedName(sha)
            if let index=try? readIndex(sha){
                // A collection from an older build keeps its index's name from now on; a name not written is tried again.
                if stored==nil{do{try durableWrite(Data(index.name.utf8),to:nameFile(sha))}catch{NativeLog.storage.error("A collection's name could not be stored: \(String(describing:error),privacy:.public)")}}
                collections.append(stored.map{index.named($0)} ?? index);continue
            }
            do{
                let data=try Data(contentsOf:file(sha));guard reviewHash(data)==sha else{throw CheckmateError.invalid(String(localized:"This collection's file is damaged.",bundle:.checkmate))}
                let date=(try? FileManager.default.attributesOfItem(atPath:file(sha).path)[.creationDate] as? Date) ?? Date()
                let derived=try Self.index(data,sha:sha,name:String(localized:"Collection",bundle:.checkmate),importedAt:date,cancelled:cancelled),name=stored ?? Self.fallbackName(derived.records)
                let index=CollectionIndex(schemaVersion:derived.schemaVersion,sha256:sha,name:name,bytes:derived.bytes,importedAt:derived.importedAt,records:derived.records,unreadable:derived.unreadable),encoded=try JSONEncoder().encode(index),label=Data(name.utf8)
                // A rebuilt index counts against the quota like any other byte of the library.
                let previous=((try? FileManager.default.attributesOfItem(atPath:indexFile(sha).path))?[.size] as? Int) ?? 0
                guard usedBytes()-previous+encoded.count+(stored==nil ? label.count:0)<=quotaBytes else{throw CheckmateError.invalid(String(localized:"The game library is full, so this collection's index could not be rebuilt. Remove a collection.",bundle:.checkmate))}
                NativeLog.storage.info("Rebuilt a collection's index, named from its \(stored==nil ? "games' Event":"stored name",privacy:.public)")
                if stored==nil{try durableWrite(label,to:nameFile(sha))};try durableWrite(encoded,to:indexFile(sha));collections.append(index)
            }catch{broken.append(BrokenCollection(id:sha,name:stored ?? String(localized:"Collection",bundle:.checkmate),error:userFacingMessage(error,fallback:String(localized:"This collection could not be read.",bundle:.checkmate))))}
        }
        // An index or name left without its file is removed with it.
        for name in names where name.hasSuffix(".index.json") && !names.contains(String(name.dropLast(11))+".pgn") || name.hasSuffix(".name") && !names.contains(String(name.dropLast(5))+".pgn"){try? FileManager.default.removeItem(at:directory.appendingPathComponent(name))}
        return (collections.sorted{$0.importedAt<$1.importedAt},broken)
    }
    /// Gives a collection a new name, kept in its name file (so a rebuilt index keeps it too). Spaces and control
    /// characters at the ends are dropped; an empty name is refused.
    public func rename(_ sha:String,to name:String)throws {
        guard Self.isDigest(sha) else{throw CheckmateError.invalid(String(localized:"Unknown collection.",bundle:.checkmate))}
        guard let clean=ReviewIndexEntry.cleanName(name).map({PGNImporter.bounded($0,scalars:Self.maximumName)}) else{throw CheckmateError.invalid(String(localized:"Give the collection a name.",bundle:.checkmate))}
        try exclusive{
            guard FileManager.default.fileExists(atPath:file(sha).path) else{throw CheckmateError.invalid(String(localized:"This collection is no longer in the library.",bundle:.checkmate))}
            let label=Data(clean.utf8),previous=FileManager.default.fileExists(atPath:nameFile(sha).path) ? ((try FileManager.default.attributesOfItem(atPath:nameFile(sha).path)[.size] as? Int) ?? 0):0
            guard usedBytes()-previous+label.count<=quotaBytes else{throw CheckmateError.invalid(String(localized:"The game library is full (\(quotaBytes/1024/1024) MiB). Remove a collection first.",bundle:.checkmate))}
            try durableWrite(label,to:nameFile(sha))
        }
    }
    /// Deletes the collection's file, index and name; an import of the same content still running is cancelled.
    public func remove(_ sha:String)throws {
        guard Self.isDigest(sha) else{throw CheckmateError.invalid(String(localized:"Unknown collection.",bundle:.checkmate))}
        removalsLock.lock();removals[sha,default:0]+=1;removalsLock.unlock()
        try exclusive{for url in [indexFile(sha),nameFile(sha),file(sha)] where FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)};try syncDirectory()}
    }
    /// Exactly the record's bytes, its hash checked.
    public func data(_ record:CollectionRecord,in collection:CollectionIndex)throws -> Data {
        let data:Data
        do{let handle=try FileHandle(forReadingFrom:file(collection.sha256));defer{try? handle.close()};try handle.seek(toOffset:UInt64(record.offset));data=try handle.read(upToCount:record.length) ?? Data()}catch{throw CheckmateError.invalid(String(localized:"This game could not be read; its collection may have been removed.",bundle:.checkmate))}
        guard data.count==record.length,reviewHash(data)==record.sha256 else{throw CheckmateError.invalid(String(localized:"This game's collection file is damaged.",bundle:.checkmate))}
        return data
    }
}
