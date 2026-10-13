import CheckmateDomain
import CheckmateSupport
import Foundation
import CryptoKit

public struct TranslatedBeat:Codable,Equatable,Sendable {public var id:String,stepTitle:String,say:String,speak:String}
public struct LessonTranslation:Codable,Equatable,Sendable {
 public var lessonID:String,title:String,teaches:[String],beats:[TranslatedBeat]
 private var mechanicsHash:String?=nil
 enum CodingKeys:String,CodingKey {case lessonID,title,teaches,beats}
 public static func ==(a:Self,b:Self)->Bool {a.lessonID==b.lessonID && a.title==b.title && a.teaches==b.teaches && a.beats==b.beats}
 public static func source(library:CourseLibrary,index:Int)->Self {
  let lesson=library.lessons[index]
  var result=Self(lessonID:lesson.id,title:lesson.title,teaches:lesson.teaches ?? [],beats:lesson.beats.enumerated().map{TranslatedBeat(id:$0.element.id ?? lesson.id+":"+String($0.offset),stepTitle:library.stepTitles[index][$0.offset],say:$0.element.say,speak:$0.element.speak ?? $0.element.say)})
  let mechanics:[[String:Any]]=lesson.beats.map {beat in var fields:[String:Any]=["hasSet":beat.hasSet,"set":beat.set as Any? ?? NSNull(),"moves":beat.moves,"remove":beat.remove,"arrows":beat.arrows as Any? ?? NSNull(),"hl":beat.hl?.map{["sq":$0.sq,"kind":$0.kind]} as Any? ?? NSNull(),"count":beat.count,"big":beat.big as Any? ?? NSNull(),"miniGame":beat.miniGame,"pause":beat.pause as Any? ?? NSNull()];if let cues=beat.moveCues{fields["moveCues"]=cues}
   // Present only where a beat has them, so lessons without guards or stages keep their fingerprints and recordings.
   if let guards=beat.guards,!guards.isEmpty{fields["guards"]=guards};if let stages=beat.stages{fields["stages"]=stages.map{["hl":$0.hl.map{["sq":$0.sq,"kind":$0.kind]},"arrows":$0.arrows,"guards":$0.guards]}};if let cues=beat.stageCues{fields["stageCues"]=cues};return fields}
  let timingEncoder=JSONEncoder();timingEncoder.outputFormatting = .sortedKeys
  let timing=(try? timingEncoder.encode(library.lessonTiming)).map{String(decoding:$0,as:UTF8.self)} ?? ""
  result.mechanicsHash=hash((try? JSONSerialization.data(withJSONObject:["beats":mechanics,"timing":timing],options:.sortedKeys)) ?? Data());return result
 }
 public var fingerprint:String {let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;var data=(try? encoder.encode(self)) ?? Data();data.append(Data((mechanicsHash ?? "").utf8));return Self.hash(data)}
 public static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
 public func validate(against source:Self)throws {
  guard lessonID==source.lessonID,beats.map(\.id)==source.beats.map(\.id),Set(beats.map(\.id)).count==beats.count,teaches.count==source.teaches.count else{throw CheckmateError.invalid("The translated lesson has missing or mismatched records.")}
  func check(_ output:String,_ input:String)throws {
   guard !output.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,output.utf8.count<=32000 else{throw CheckmateError.invalid("The translated text is empty or too long.")}
   let regex=try NSRegularExpression(pattern:"(?<![A-Za-z0-9])(?:[a-h][1-8](?:[a-h][1-8][qrbn]?)?|O-O(?:-O)?|[KQRBN][a-h]?[1-8]?x?[a-h][1-8][+#]?)(?![A-Za-z0-9])")
   func notation(_ s:String)->[String] {regex.matches(in:s,range:NSRange(s.startIndex...,in:s)).compactMap{Range($0.range,in:s).map{String(s[$0])}}.sorted()}
   guard notation(output)==notation(input) else{throw CheckmateError.invalid("The translation changed chess coordinates or notation.")}
  }
  try check(title,source.title)
  for (a,b) in zip(teaches,source.teaches){try check(a,b)}
  for (a,b) in zip(beats,source.beats){try check(a.stepTitle,b.stepTitle);try check(a.say,b.say);try check(a.speak,b.speak)}
 }
 public static var outputSchema:[String:Any] {
  let text:[String:Any]=["type":"string"],beat:[String:Any]=["type":"object","additionalProperties":false,"required":["id","stepTitle","say","speak"],"properties":["id":text,"stepTitle":text,"say":text,"speak":text]]
  return ["type":"object","additionalProperties":false,"required":["lessonID","title","teaches","beats"],"properties":["lessonID":text,"title":text,"teaches":["type":"array","items":text],"beats":["type":"array","items":beat]]]
 }
 public static func decode(_ data:Data)throws->Self {
  guard data.count<=2_000_000,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(root.keys)==Set(["lessonID","title","teaches","beats"]),let beats=root["beats"] as? [[String:Any]],beats.allSatisfy({Set($0.keys)==Set(["id","stepTitle","say","speak"])}) else{throw CheckmateError.invalid("The translation response is invalid.")}
  return try JSONDecoder().decode(Self.self,from:data)
 }
}
public struct LessonClip:Codable,Equatable,Sendable {public var beatID:String,scriptHash:String,audioHash:String,seconds:Double,model:String,voice:String,generation:Int}
public struct LessonPack:Codable,Sendable {public var version:Int=1;public var sourceFingerprint:String,locale:String,voice:String;public var translation:LessonTranslation;public var clips:[LessonClip]}
/// All filenames are hashes generated here; callers cannot supply filesystem paths.
private struct LessonTextCheckpoint:Codable {var version:Int=1;var sourceFingerprint:String,locale:String;var text:LessonTranslation}
public final class LessonPackStore:@unchecked Sendable {
 public let directory:URL
 public let unavailableReason:String?
 private let lock=NSRecursiveLock()
 private init(unavailableDirectory:URL,reason:String){directory=unavailableDirectory.appendingPathComponent("LessonLanguages");unavailableReason=reason}
 public static func unavailable(directory:URL,reason:String)->LessonPackStore {LessonPackStore(unavailableDirectory:directory,reason:reason)}
 public init(directory:URL)throws {unavailableReason=nil;if (try? directory.resourceValues(forKeys:[.isSymbolicLinkKey]))?.isSymbolicLink==true{throw CheckmateError.invalid("The language pack directory is unsafe.")};self.directory=directory.resolvingSymlinksInPath().appendingPathComponent("LessonLanguages");var ancestor=self.directory;while ancestor.path != "/" {if FileManager.default.fileExists(atPath:ancestor.path),!["/var","/tmp"].contains(ancestor.path),(try ancestor.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink==true{throw CheckmateError.invalid("The language pack directory is unsafe.")};ancestor=ancestor.deletingLastPathComponent()};try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
 private func url(_ key:String)->URL {directory.appendingPathComponent(LessonTranslation.hash(Data(key.utf8)))}
 private func validateRoot()throws {if let unavailableReason{throw CheckmateError.unavailable(unavailableReason)};var ancestor=directory;while ancestor.path != "/" {if !["/var","/tmp"].contains(ancestor.path),(try? ancestor.resourceValues(forKeys:[.isSymbolicLinkKey]))?.isSymbolicLink==true{throw CheckmateError.invalid("The language pack directory is unsafe.")};ancestor=ancestor.deletingLastPathComponent()}}
 /// The size of a regular, non-link file directly inside the store, within `limit`; anything else is invalid.
 private func checkedSize(_ file:URL,limit:Int)throws->Int {
  try validateRoot()
  let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey]);guard values.isSymbolicLink != true,values.isRegularFile==true,let size=values.fileSize,size<=limit,file.resolvingSymlinksInPath().deletingLastPathComponent().path==directory.resolvingSymlinksInPath().path else{throw CheckmateError.invalid("The stored language pack is invalid.")};return size
 }
 private func safeRead(_ file:URL,limit:Int)throws->Data {_ = try checkedSize(file,limit:limit);return try Data(contentsOf:file)}
 /// Recordings already hashed in this process, keyed by file identity. Writes are atomic (a replaced file gets a new
 /// inode), so a rescan re-hashes only files written since; each launch still verifies every file once.
 private struct VerifiedAudio:Equatable {let stamp:String,hash:String}
 private var verifiedAudio:[String:VerifiedAudio]=[:]
 /// How many recordings were read and hashed in full (observable, so a rescan's cost is testable).
 private(set) var audioVerifications=0
 private func stamp(_ file:URL)->String? {guard let attributes=try? FileManager.default.attributesOfItem(atPath:file.path),let inode=attributes[.systemFileNumber] as? NSNumber,let size=attributes[.size] as? NSNumber,let modified=attributes[.modificationDate] as? Date else{return nil};return "\(inode)|\(size)|\(modified.timeIntervalSince1970)"}
 private func write(_ data:Data,to file:URL)throws {try validateRoot();if FileManager.default.fileExists(atPath:file.path){_ = try safeRead(file,limit:32_000_000)};try data.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
 /// Whether a translated-text file exists for this lesson, valid or not, so an invalid one can still be discarded.
 public func hasStoredText(source:LessonTranslation,locale:String)->Bool {FileManager.default.fileExists(atPath:url("text|\(source.fingerprint)|\(locale)").path)}
 public func translation(source:LessonTranslation,locale:String)throws->LessonTranslation? {
  lock.lock();defer{lock.unlock()};let file=url("text|\(source.fingerprint)|\(locale)");guard FileManager.default.fileExists(atPath:file.path) else{return nil};let data=try safeRead(file,limit:2_000_000);let result:LessonTranslation;if let checkpoint=try? JSONDecoder().decode(LessonTextCheckpoint.self,from:data){guard checkpoint.version==1,checkpoint.sourceFingerprint==source.fingerprint,checkpoint.locale==locale else{throw CheckmateError.invalid("The stored translation is outdated.")};result=checkpoint.text}else{result=try LessonTranslation.decode(data)};try result.validate(against:source);return result
 }
 public func saveTranslation(_ text:LessonTranslation,source:LessonTranslation,locale:String)throws {lock.lock();defer{lock.unlock()};guard LessonLanguages.valid(locale) else{throw CheckmateError.invalid("Choose a valid language identifier.")};try text.validate(against:source);try write(JSONEncoder().encode(LessonTextCheckpoint(sourceFingerprint:source.fingerprint,locale:locale,text:text)),to:url("text|\(source.fingerprint)|\(locale)"))}
 private func manifestURL(source:LessonTranslation,locale:String,voice:String)->URL {url("pack|\(source.fingerprint)|\(locale)|\(voice)|1")}
 /// Whether cleanup can attribute a decoded manifest's recordings: a supported version and voice, stored under its own
 /// name. Any other manifest (newer, or not written here) is uninspected, so no audio counts as orphaned while it exists.
 private func recognised(_ pack:LessonPack,at file:URL)->Bool {pack.version==1 && LessonLanguages.valid(pack.locale) && ["cedar","marin"].contains(pack.voice) && file.lastPathComponent==url("pack|\(pack.sourceFingerprint)|\(pack.locale)|\(pack.voice)|1").lastPathComponent}
 public func partialPack(source:LessonTranslation,locale:String,voice:String)throws->LessonPack? {
  lock.lock();defer{lock.unlock()};let file=manifestURL(source:source,locale:locale,voice:voice);guard FileManager.default.fileExists(atPath:file.path) else{return nil};let pack=try JSONDecoder().decode(LessonPack.self,from:safeRead(file,limit:2_000_000));guard pack.version==1,pack.sourceFingerprint==source.fingerprint,pack.locale==locale,pack.voice==voice,["cedar","marin"].contains(voice) else{throw CheckmateError.invalid("The stored lesson pack is outdated.")};try pack.translation.validate(against:source);guard pack.clips.allSatisfy({source.beats.map(\.id).contains($0.beatID)}),Set(pack.clips.map(\.beatID)).count==pack.clips.count else{throw CheckmateError.invalid("Duplicate stored recordings.")};return pack
 }
 public func clipURL(pack:LessonPack,beatID:String)throws->URL? {
  guard let clip=pack.clips.first(where:{$0.beatID==beatID}),let beat=pack.translation.beats.first(where:{$0.id==beatID}),clip.generation==1,LessonRecording.acceptedModel(clip.model),clip.voice==pack.voice,clip.scriptHash==LessonTranslation.hash(Data(beat.speak.utf8)),clip.seconds.isFinite,clip.seconds>0,clip.seconds<=600 else{return nil}
  lock.lock();defer{lock.unlock()}
  let file=url("audio|\(pack.sourceFingerprint)|\(pack.locale)|\(pack.voice)|\(beatID)|1");guard FileManager.default.fileExists(atPath:file.path) else{return nil}
  let before=stamp(file),size=try checkedSize(file,limit:28_800_044);guard abs(Double(size-44)/48000-clip.seconds)<0.001 else{return nil}
  if let before,verifiedAudio[file.path]==VerifiedAudio(stamp:before,hash:clip.audioHash){return file}
  let data=try Data(contentsOf:file);audioVerifications+=1
  guard data.count>44,LessonRecording.validWAV(data),LessonTranslation.hash(data)==clip.audioHash,abs(Double(data.count-44)/48000-clip.seconds)<0.001 else{return nil}
  if let before,stamp(file)==before{verifiedAudio[file.path]=VerifiedAudio(stamp:before,hash:clip.audioHash)};return file
 }
 /// Removes one clip's recording and its manifest entry; the lesson's other clips and its text are kept. Returns
 /// whether anything was stored for that clip.
 @discardableResult public func removeClip(source:LessonTranslation,locale:String,voice:String,beatID:String)throws->Bool {
  lock.lock();defer{lock.unlock()};try validateRoot();var removed=false
  if var pack=try partialPack(source:source,locale:locale,voice:voice),pack.clips.contains(where:{$0.beatID==beatID}){pack.clips.removeAll{$0.beatID==beatID};try write(JSONEncoder().encode(pack),to:manifestURL(source:source,locale:locale,voice:voice));removed=true}
  let audio=url("audio|\(source.fingerprint)|\(locale)|\(voice)|\(beatID)|1");if FileManager.default.fileExists(atPath:audio.path){try FileManager.default.removeItem(at:audio);removed=true}
  return removed
 }
 public func completePack(source:LessonTranslation,locale:String,voice:String)throws->LessonPack? {try validatedPack(source:source,locale:locale,voice:voice)?.0}
 public func saveClip(pcm:Data,transcript:String,beatID:String,source:LessonTranslation,locale:String,voice:String,model:String)throws->LessonPack {
  lock.lock();defer{lock.unlock()};guard LessonRecording.acceptedModel(model),["cedar","marin"].contains(voice) else{throw CheckmateError.invalid("The recording model or voice is not supported by this generation profile.")};guard let translation=try translation(source:source,locale:locale),let beat=translation.beats.first(where:{$0.id==beatID}) else{throw CheckmateError.invalid("Translate the lesson before recording.")};let seconds=try LessonRecording.validate(pcm:pcm,transcript:transcript,script:beat.speak,locale:locale),wav=LessonRecording.wav(pcm)
  var pack=try partialPack(source:source,locale:locale,voice:voice) ?? LessonPack(sourceFingerprint:source.fingerprint,locale:locale,voice:voice,translation:translation,clips:[])
  try write(wav,to:url("audio|\(source.fingerprint)|\(locale)|\(voice)|\(beatID)|1"));pack.clips.removeAll{$0.beatID==beatID};pack.clips.append(LessonClip(beatID:beatID,scriptHash:LessonTranslation.hash(Data(beat.speak.utf8)),audioHash:LessonTranslation.hash(wav),seconds:seconds,model:model,voice:voice,generation:1));try write(JSONEncoder().encode(pack),to:manifestURL(source:source,locale:locale,voice:voice));return pack
 }
 /// Removes translated text, manifests and recordings made for earlier versions of the lessons (their source
 /// fingerprint is no longer any lesson's), then their orphaned audio. Current work and unreadable files are kept, and
 /// while any stored file cannot be inspected no audio counts as orphaned: it may belong to that file.
 /// Returns the number of files and bytes removed.
 @discardableResult public func purgeOutdated(library:CourseLibrary)throws -> (files:Int,bytes:Int64) {
  lock.lock();defer{lock.unlock()};try validateRoot()
  let current=Set(library.lessons.indices.map{LessonTranslation.source(library:library,index:$0).fingerprint})
  let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey]);guard files.count<=1_000_000 else{throw CheckmateError.unavailable("The lesson cache is too large to inspect.")}
  var audio:[URL]=[],retained:Set<String>=[],outdated:[URL]=[],uninspected=false
  for file in files {
   guard file.lastPathComponent.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{continue};let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey]);guard values.isSymbolicLink != true,values.isRegularFile==true else{continue}
   let handle=try FileHandle(forReadingFrom:file);let prefix=try handle.read(upToCount:4) ?? Data();try handle.close();if prefix==Data("RIFF".utf8){audio.append(file);continue};guard (values.fileSize ?? Int.max)<=2_000_000,let data=try? safeRead(file,limit:2_000_000) else{uninspected=true;continue}
   if let pack=try? JSONDecoder().decode(LessonPack.self,from:data) {
    guard recognised(pack,at:file) else{uninspected=true;continue}
    if current.contains(pack.sourceFingerprint){for beat in pack.translation.beats{retained.insert(url("audio|\(pack.sourceFingerprint)|\(pack.locale)|\(pack.voice)|\(beat.id)|1").lastPathComponent)}}else{outdated.append(file)}
   }else if let checkpoint=try? JSONDecoder().decode(LessonTextCheckpoint.self,from:data){if checkpoint.version==1,!current.contains(checkpoint.sourceFingerprint),file.lastPathComponent==url("text|\(checkpoint.sourceFingerprint)|\(checkpoint.locale)").lastPathComponent{outdated.append(file)}
   }else if (try? LessonTranslation.decode(data))==nil{uninspected=true}
  }
  var count=0,bytes:Int64=0
  for file in outdated+(uninspected ? []:audio.filter{!retained.contains($0.lastPathComponent)}) {bytes+=Int64((try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0);try FileManager.default.removeItem(at:file);count+=1}
  return (count,bytes)
 }
 /// Remove only orphaned audio. Older paid checkpoints and manifests survive source changes; while any stored file
 /// cannot be decoded or attributed (damaged, or written by a newer version) no audio counts as orphaned.
 public func sweepStale(library:CourseLibrary)throws {lock.lock();defer{lock.unlock()};try validateRoot();let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey]);guard files.count<=1_000_000 else{throw CheckmateError.unavailable("The lesson cache is too large to inspect. Remove recordings explicitly to continue.")};var audio:[URL]=[],retained:Set<String>=[],uninspected=false
  for file in files {guard file.lastPathComponent.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{continue};let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey]);guard values.isSymbolicLink != true,values.isRegularFile==true else{continue};let handle=try FileHandle(forReadingFrom:file);let prefix=try handle.read(upToCount:4) ?? Data();try handle.close();if prefix==Data("RIFF".utf8){audio.append(file);continue};guard (values.fileSize ?? Int.max)<=2_000_000 else{uninspected=true;continue};let data=try safeRead(file,limit:2_000_000)
   if let pack=try? JSONDecoder().decode(LessonPack.self,from:data){if recognised(pack,at:file){for beat in pack.translation.beats{retained.insert(url("audio|\(pack.sourceFingerprint)|\(pack.locale)|\(pack.voice)|\(beat.id)|1").lastPathComponent)}}else{uninspected=true}}
   else if (try? JSONDecoder().decode(LessonTextCheckpoint.self,from:data))==nil,(try? LessonTranslation.decode(data))==nil{uninspected=true}
  };for file in audio where !uninspected && !retained.contains(file.lastPathComponent){try FileManager.default.removeItem(at:file)}
 }
 public func discardTranslation(source:LessonTranslation,locale:String)throws {lock.lock();defer{lock.unlock()};try validateRoot();for voice in ["cedar","marin"]{try remove(source:source,locale:locale,voice:voice)};let text=url("text|\(source.fingerprint)|\(locale)");if FileManager.default.fileExists(atPath:text.path){try FileManager.default.removeItem(at:text)}}
 public func validatedPack(source:LessonTranslation,locale:String,voice:String)throws->(LessonPack,[String:URL])? {lock.lock();defer{lock.unlock()};guard let pack=try partialPack(source:source,locale:locale,voice:voice),pack.clips.count==source.beats.count else{return nil};var urls:[String:URL]=[:];for beat in source.beats{guard let file=try clipURL(pack:pack,beatID:beat.id) else{return nil};urls[beat.id]=file};return (pack,urls)}
 public func remove(source:LessonTranslation,locale:String,voice:String)throws {lock.lock();defer{lock.unlock()};try validateRoot();let file=manifestURL(source:source,locale:locale,voice:voice);if FileManager.default.fileExists(atPath:file.path){try FileManager.default.removeItem(at:file)};for beat in source.beats {let audio=url("audio|\(source.fingerprint)|\(locale)|\(voice)|\(beat.id)|1");if FileManager.default.fileExists(atPath:audio.path){try FileManager.default.removeItem(at:audio)}}}
}
