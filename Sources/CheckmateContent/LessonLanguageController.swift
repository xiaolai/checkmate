import CheckmateAssets
import CheckmateDomain
import CheckmateSupport
import Foundation
import Combine
/// What Translate or Record / Resume would do for every lesson, shown for confirmation before anything is requested.
/// `seconds` is estimated from earlier completed runs on this Mac (nil before the first); `untranslated` counts the
/// lessons a recording job skips because they have no translated text.
public struct LessonJobPlan:Equatable,Sendable {
 public let mode:String,language:String,voice:String,lessons:Int,clips:Int,untranslated:Int,seconds:Double?
 private static func lessonCount(_ n:Int)->String {String(localized:"\(n) lessons",bundle:.checkmate)}
 public var title:String {mode=="translate" ? String(localized:"Translate \(lessons) lessons into \(language)?",bundle:.checkmate,comment:"The second value is a language name"):String(localized:"Record \(clips) clips for \(Self.lessonCount(lessons))?",bundle:.checkmate,comment:"The second value is a number of lessons, such as “3 lessons”")}
 public var action:String {mode=="translate" ? String(localized:"Translate",bundle:.checkmate):String(localized:"Record",bundle:.checkmate,comment:"Verb: record the narration audio")}
 public var message:String {
  var parts=[mode=="translate" ? String(localized:"Each lesson is one translation request on your signed-in account.",bundle:.checkmate):String(localized:"Each clip is one recording request on your signed-in account, in the \(voice.capitalized) voice.",bundle:.checkmate)]
  if mode != "translate",untranslated>0{parts.append(String(localized:"\(untranslated) lessons have no translated text yet and are skipped; translate them first.",bundle:.checkmate))}
  if let seconds{let minutes=Int((seconds/60).rounded(.up));parts.append(seconds<60 ? String(localized:"Estimated time: less than a minute, judged from earlier runs on this Mac.",bundle:.checkmate):String(localized:"Estimated time: about \(minutes) minutes, judged from earlier runs on this Mac.",bundle:.checkmate))}
  else{parts.append(String(localized:"No time estimate yet: there are no earlier \(mode=="translate" ? "translations":"recordings") on this Mac to judge from.",bundle:.checkmate))}
  parts.append(String(localized:"You can cancel at any time; finished work is kept.",bundle:.checkmate))
  return parts.joined(separator:" ")
 }
}
/// What is stored for one lesson in one language and voice, as Settings' lesson list shows it (L-27). `stale` is a
/// stored file this version cannot use (damaged, or made for another version), which counts as missing.
public struct LessonStoredStatus:Equatable,Sendable {
 public let translated:Bool,recorded:Int,clips:Int,stale:Bool
 public init(translated:Bool,recorded:Int,clips:Int,stale:Bool){self.translated=translated;self.recorded=recorded;self.clips=clips;self.stale=stale}
 /// "None", "3 of 12" or "All 12".
 public var recordedText:String {recorded==0 ? String(localized:"None",bundle:.checkmate):recorded==clips ? String(localized:"All \(clips)",bundle:.checkmate):"\(recorded) of \(clips)"}
}
/// A part of the course in Settings' lesson picker, with its lessons' indices.
public struct LessonGroup:Equatable,Sendable {public let title:String,lessons:[Int]}
@MainActor public final class LessonLanguageController:ObservableObject {
    /// The problem count a running job appends to its progress, as its own counted phrase.
    nonisolated static func problemsSoFar(_ count:Int)->String {count==0 ? "":" · "+String(localized:"\(count) problems so far",bundle:.checkmate)}
 public let library:CourseLibrary,store:LessonPackStore,usage:UsageLedger
 @Published public var language="en" {didSet{if oldValue != language{selectionChanged()}}}
 @Published public var voice="cedar" {didSet{if oldValue != voice{selectionChanged()}}}
 @Published public var selectedLesson=0 {didSet{if oldValue != selectedLesson{selectionChanged()}}}
 @Published public var allLessons=false
 @Published public private(set) var busy=false
 /// Cleanup runs to completion (removing files is local and each removal is final), so only lesson jobs can be cancelled.
 @Published public private(set) var purging=false
 public var canCancel:Bool {busy && !purging}
 /// Automation fixtures hold cleanup open this long, so its running state can be observed from outside the app.
 public var cleanupPause:Duration = .zero
 @Published public private(set) var status=String(localized:"Select a language, then translate a lesson.",bundle:.checkmate)
 @Published public private(set) var inspection=""
 @Published public private(set) var previewURL:URL?
 @Published public private(set) var storedStatus=String(localized:"No stored recordings for this selection.",bundle:.checkmate)
 @Published public private(set) var accountStatus=String(localized:"Account status has not been refreshed. Voice subscription attribution is unknown.",bundle:.checkmate)
 public var voiceConflict:()->Bool={false},beforeRemove:()->Void={},playPreview:((URL)->Void)?,onPacksChanged:()->Void={},onSelectionChange:()->Void={}
 public private(set) var recording=false
 private let translator:any LessonTranslationProvider,recorder:any LessonRecordingProvider
 private var task:Task<Void,Never>?,generation=UUID(),accountTask:Task<Void,Never>?
 /// The lessons and clips that failed in the last job, named for the learner, and their keys so a Resume tries them last.
 @Published public private(set) var problems:[String]=[]
 private var failedLastRun:Set<String>=[]
 private var lastAccountStatus:String?,lastAccountRefresh:Date?
 private let accountAuthMetadata:(@Sendable ()->String)?
 private var accountAuthStamp:String?,accountMonitor:Timer?,accountSnapshotGeneration=UUID()
 private var accountSnapshotStale=false
 private nonisolated static func liveAuthMetadata()->String {
  guard let attributes=try? FileManager.default.attributesOfItem(atPath:VoiceGateway.credentialURL.path) else{return "unavailable"}
  let modified=(attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
  let size=(attributes[.size] as? NSNumber)?.uint64Value ?? 0
  let inode=(attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
  return "\(modified)|\(size)|\(inode)"
 }
 private var selectionTask:Task<Void,Never>?,selectionGeneration=UUID()
 public init(library:CourseLibrary,directory:URL,usage:UsageLedger,translator:any LessonTranslationProvider=CodexSubscriptionClient(),recorder:any LessonRecordingProvider=RealtimeLessonRecorder(),accountAuthMetadata:(@Sendable ()->String)?=nil)throws {self.library=library;do{store=try LessonPackStore(directory:directory)}catch{store=LessonPackStore.unavailable(directory:directory,reason:String(localized:"Offline lesson storage is unavailable. English lessons remain available.",bundle:.checkmate))};self.usage=usage;self.translator=translator;self.recorder=recorder
  if let accountAuthMetadata{self.accountAuthMetadata=accountAuthMetadata}else if !NativePolicy.silent,translator is CodexSubscriptionClient{self.accountAuthMetadata={Self.liveAuthMetadata()}}else{self.accountAuthMetadata=nil}
  if !NativePolicy.silent,self.accountAuthMetadata != nil {
   accountMonitor=Timer.scheduledTimer(withTimeInterval:3,repeats:true){[weak self] _ in Task{@MainActor in await self?.checkAccountAuthenticationMetadata()}}
  }
  let store=self.store;if let problem=store.unavailableReason{status=problem}else{Task.detached{try? store.sweepStale(library:library)}}}
 /// What is stored for each lesson in the chosen language and voice, in course order (L-27); empty while it is read.
 @Published public private(set) var lessonStatuses:[LessonStoredStatus]=[]
 private var statusTask:Task<Void,Never>?,statusKey=""
 /// The lessons grouped by course section, in course order (L-26).
 public nonisolated static func groups(_ library:CourseLibrary)->[LessonGroup] {
  var groups:[LessonGroup]=[]
  for (index,lesson) in library.lessons.enumerated() {if groups.last?.title==lesson.section{groups[groups.count-1]=LessonGroup(title:lesson.section,lessons:groups[groups.count-1].lessons+[index])}else{groups.append(LessonGroup(title:lesson.section,lessons:[index]))}}
  return groups
 }
 /// Reads every lesson's status when the language or voice changes, or (`force`) after stored files changed.
 private func refreshStatuses(force:Bool){
  let key=language+"|"+voice;guard force || key != statusKey else{return};if key != statusKey{lessonStatuses=[]};statusKey=key;statusTask?.cancel()
  guard store.unavailableReason==nil else{lessonStatuses=[];return}
  let store=store,library=library,locale=language,voice=self.voice
  statusTask=Task{[weak self] in
   let statuses=await Task.detached{library.lessons.indices.map{store.status(source:LessonTranslation.source(library:library,index:$0),locale:locale,voice:voice)}}.value
   guard let self,!Task.isCancelled,self.language==locale,self.voice==voice else{return};self.lessonStatuses=statuses
  }
 }
 private func selectionChanged(invalidatePreview:Bool=true){refreshStatuses(force:!invalidatePreview);if invalidatePreview{previewURL=nil;inspection="";storedStatus=String(localized:"Checking stored lesson data…",bundle:.checkmate);onSelectionChange()};selectionTask?.cancel();selectionGeneration=UUID();let generation=selectionGeneration;guard !busy,library.lessons.indices.contains(selectedLesson) else{return};let source=LessonTranslation.source(library:library,index:selectedLesson),locale=language,voice=self.voice,store=self.store;selectionTask=Task{[weak self] in
   // Damaged text and damaged recordings are reported apart, each with the narrowest action that repairs it.
   let result=await Task.detached{()->(String,String) in let translation:LessonTranslation?;do{translation=try store.translation(source:source,locale:locale)}catch{return ("",String(localized:"This lesson's stored translation is damaged or out of date. Choose Discard Translated Text, then Translate it again.",bundle:.checkmate))};guard let translation else{return ("",String(localized:"No translated text or recordings for this selection.",bundle:.checkmate))};let text=([translation.title]+translation.teaches+translation.beats.map{$0.stepTitle+"\n"+$0.say}).joined(separator:"\n\n");do{if let pack=try store.completePack(source:source,locale:locale,voice:voice){return (text,String(localized:"Complete offline lesson: \(pack.clips.count) verified recordings.",bundle:.checkmate))};let count=(try store.partialPack(source:source,locale:locale,voice:voice))?.clips.count ?? 0;return (text,String(localized:"Translated text stored; \(count) of \(source.beats.count) recordings stored. Incomplete lessons use English.",bundle:.checkmate))}catch{return (text,String(localized:"Translated text stored, but this voice's stored recordings are damaged or out of date. Choose Remove Stored Lesson, then Record / Resume; the translated text is kept.",bundle:.checkmate))}}.value
   guard let self,!Task.isCancelled,self.selectionGeneration==generation,!self.busy else{return};self.inspection=result.0;self.storedStatus=result.1
 }}
 /// Discard is available whenever there is stored text to remove, including a damaged file that cannot be shown.
 public var canDiscardTranslation:Bool {!busy && (allLessons || !inspection.isEmpty || (library.lessons.indices.contains(selectedLesson) && store.hasStoredText(source:LessonTranslation.source(library:library,index:selectedLesson),locale:language)))}
 /// Frees the space held by translations and recordings made for earlier versions of the lessons.
 public func purgeOutdated(){
  // A job of its own: no translation or recording starts while files are removed, and only this cleanup reports its result.
  guard !busy else{return};let store=store,library=library,id=UUID(),pause=cleanupPause;generation=id;busy=true;purging=true;status=String(localized:"Removing outdated translations…",bundle:.checkmate)
  task=Task{[weak self] in
   if pause > .zero{try? await Task.sleep(for:pause)}
   let result:String;do{let removed=try await Task.detached{try store.purgeOutdated(library:library)}.value;result=removed.files==0 ? String(localized:"No outdated translations or recordings to remove.",bundle:.checkmate):String(localized:"Removed \(removed.files) outdated files (\(ByteCountFormatter.string(fromByteCount:removed.bytes,countStyle:.file))).",bundle:.checkmate,comment:"The second value is a file size, such as “2 MB”")}catch{result=userFacingMessage(error,fallback:String(localized:"Outdated translations could not be removed.",bundle:.checkmate))}
   guard let self,self.generation==id else{return};self.busy=false;self.purging=false;self.task=nil;self.status=result;self.selectionChanged(invalidatePreview:false)
  }
 }
 public func translate(){start(mode:"translate")}
 public func record(){start(mode:"record")}
 public func preview(){start(mode:"preview")}
 /// Why a job cannot start now, or nil.
 private func startProblem(mode:String)->String? {
  if let problem=store.unavailableReason{return problem}
  guard !busy,!planning,LessonLanguages.normalizedSelection(language)==language,language != "en",library.lessons.indices.contains(selectedLesson),["cedar","marin"].contains(voice) else{return String(localized:"Choose a supported language and lesson first.",bundle:.checkmate)}
  if mode != "translate",voiceConflict(){return String(localized:"Disconnect the voice coach before generating lesson recordings.",bundle:.checkmate)}
  return nil
 }
 /// While Translate or Record for every lesson checks the sign-in and counts the work.
 @Published public private(set) var planning=false
 /// Before Translate or Record for every lesson: confirms the sign-in, then counts what is still to do, so the learner
 /// can confirm a long job before anything is requested. Nil, with the reason in `status`, when there is nothing to
 /// confirm: the sign-in failed, the selection changed meanwhile, or every lesson is already done.
 public func planAll(mode:String) async -> LessonJobPlan? {await plan(mode:mode,only:nil)}
 /// A row's Translate or Record in the lesson list: selects that lesson, then checks the sign-in and counts its work
 /// exactly as for every lesson, so nothing is requested until the learner confirms.
 public func plan(mode:String,lesson:Int) async -> LessonJobPlan? {
  guard library.lessons.indices.contains(lesson) else{return nil}
  guard !busy,!planning else{status=String(localized:"Wait for the current job to finish, or cancel it.",bundle:.checkmate);return nil}
  allLessons=false;selectedLesson=lesson;return await plan(mode:mode,only:lesson)
 }
 private func plan(mode:String,only:Int?) async -> LessonJobPlan? {
  guard mode=="translate" || mode=="record" else{return nil}
  if let problem=startProblem(mode:mode){status=problem;return nil}
  let locale=language,chosenVoice=voice,store=store,library=library;planning=true;defer{planning=false};status=String(localized:"Checking your sign-in…",bundle:.checkmate)
  do{_=try await translator.accountStatus()}catch{status=String(localized:"Nothing was started: your sign-in could not be confirmed. ",bundle:.checkmate)+userFacingMessage(error,fallback:String(localized:"Sign in, then try again.",bundle:.checkmate));return nil}
  let counts=await Task.detached{()->(lessons:Int,clips:Int,untranslated:Int) in var lessons=0,clips=0,untranslated=0
   for index in only.map({[$0]}) ?? Array(library.lessons.indices) {let source=LessonTranslation.source(library:library,index:index)
    // Damaged text or recordings count as missing: this is a count for the confirmation, and the job itself replaces
    // or reports each damaged file.
    let text:LessonTranslation?;do{text=try store.translation(source:source,locale:locale)}catch{text=nil}
    if mode=="translate"{if text==nil{lessons+=1};continue}
    guard text != nil else{untranslated+=1;continue}
    let stored:Int;do{stored=try store.partialPack(source:source,locale:locale,voice:chosenVoice)?.clips.count ?? 0}catch{stored=0}
    let missing=source.beats.count-stored;if missing>0{lessons+=1;clips+=missing}}
   return (lessons,clips,untranslated)}.value
  guard language==locale,voice==chosenVoice,only==nil ? allLessons:(!allLessons && selectedLesson==only) else{status=String(localized:"The selection changed while it was checked. Choose \(mode=="translate" ? "Translate":"Record / Resume") again.",bundle:.checkmate);return nil}
  let name=LessonLanguages.name(locale)
  if counts.lessons==0,only != nil{status=mode=="translate" ? String(localized:"This lesson already has translated text in \(name).",bundle:.checkmate):counts.untranslated>0 ? String(localized:"This lesson has no translated text yet; translate it first.",bundle:.checkmate):String(localized:"This lesson already has all its recordings.",bundle:.checkmate);return nil}
  if counts.lessons==0{status=mode=="translate" ? String(localized:"Every lesson already has translated text in \(name).",bundle:.checkmate):String(localized:"Every translated lesson already has all its recordings.",bundle:.checkmate)+(counts.untranslated>0 ? String(localized:" \(counts.untranslated) lessons have no translated text yet; translate them first.",bundle:.checkmate):"");return nil}
  let activity:UsageActivity=mode=="translate" ? .translation:.lessonRecording,each=usage.records.filter{$0.activity==activity && $0.status == .completed}.map{$0.updatedAt.timeIntervalSince($0.startedAt)}.sorted()
  let typical=each.isEmpty ? nil:each[each.count/2]
  status=String(localized:"Waiting for you to confirm.",bundle:.checkmate)
  return LessonJobPlan(mode:mode,language:name,voice:chosenVoice,lessons:counts.lessons,clips:counts.clips,untranslated:counts.untranslated,seconds:typical.map{$0*Double(mode=="translate" ? counts.lessons:counts.clips)})
 }
 /// The learner said no to a planned job: nothing was requested.
 public func declinePlan(){guard !busy else{return};status=String(localized:"Nothing was started.",bundle:.checkmate)}
 private func start(mode:String) {
  if let problem=startProblem(mode:mode){status=problem;return}
  let locale=language,chosenVoice=voice,indices=allLessons && mode != "preview" ? Array(library.lessons.indices):[selectedLesson],id=UUID();generation=id;busy=true;recording=mode != "translate";previewURL=nil;problems=[]
  // Each lesson and clip either completes or becomes a named problem; the job continues with the rest, retries last
  // run's failures last (never re-billing the same failure first), and stops after three failures in a row.
  let retryLast=failedLastRun
  task=Task{[weak self] in
   guard let self else{return};var changedPacks=false,problems:[String]=[],failed:Set<String>=[],consecutive=0
   defer{if self.generation==id{self.busy=false;self.recording=false;self.task=nil;self.problems=problems;self.selectionChanged(invalidatePreview:false);if changedPacks{self.onPacksChanged()}}}
   @MainActor func problem(_ key:String,_ place:String,_ error:Error)throws {
    if error is CancellationError || Task.isCancelled || error is LessonJobStopped{throw error}
    problems.append(place+": "+userFacingMessage(error,fallback:String(localized:"it could not be completed.",bundle:.checkmate,comment:"Follows a lesson’s name and a colon")));failed.insert(key);consecutive+=1;self.problems=problems
    if consecutive>=3{throw LessonJobStopped(message:String(localized:"Stopped after three failures in a row. Fix the cause, then Resume.",bundle:.checkmate))}
   }
   // Settings can change the language or voice mid-job (Import Progress); the job keeps its own, and shows its text
   // and preview only while they are still the selected ones, never under another language's label.
   @MainActor func shown(voice:Bool)->Bool {self.language==locale && (!voice || self.voice==chosenVoice)}
   // Clips that failed last run wait for a second pass, after every other clip of every selected lesson, so failures
   // that persist in one lesson cannot stop a Resume before later lessons are reached.
   let ordered=indices.filter{!retryLast.contains(self.library.lessons[$0].id)}+indices.filter{retryLast.contains(self.library.lessons[$0].id)}
   let retried=mode=="translate" ? []:ordered.filter{index in let prefix=self.library.lessons[index].id+":";return retryLast.contains{$0.hasPrefix(prefix)}}
   let passes=ordered.enumerated().map{(ordinal:$0.offset,index:$0.element,retry:false)}+retried.map{(ordinal:ordered.firstIndex(of:$0)!,index:$0,retry:true)}
   do {for (ordinal,index,retry) in passes {
    try Task.checkCancellation();let source=LessonTranslation.source(library:self.library,index:index),place=String(localized:"Lesson \(index+1) “\(source.title)”",bundle:.checkmate)
    if retry,failed.contains(source.lessonID){continue}
    self.status=(mode == "translate" ? String(localized:"Lesson \(ordinal+1) of \(ordered.count): translating",bundle:.checkmate):String(localized:"Lesson \(ordinal+1) of \(ordered.count): recording",bundle:.checkmate))+Self.problemsSoFar(problems.count)
    do {
     var text=try await Task.detached{try self.store.translation(source:source,locale:locale)}.value
     if mode=="translate",text==nil {
      let operation=self.usage.begin(activity:.translation,provider:"codex",sessionID:UUID().uuidString,locale:locale,lessonID:source.lessonID)
      do {
       let result=try await self.translator.translate(source:source,locale:locale,onUsage:{[weak self] turn,model,tokens in Task{@MainActor in self?.usage.record(operationID:operation,providerID:turn,tokens:tokens,status:.running,cumulative:true,model:model)}})
       self.usage.record(operationID:operation,providerID:result.turnID,tokens:result.tokens,status:.running,cumulative:true,estimatedCredits:result.estimatedCredits,estimatedUSD:result.estimatedUSD,model:result.model)
       try await Task.detached{try self.store.saveTranslation(result.text,source:source,locale:locale)}.value;text=result.text
       self.usage.record(operationID:operation,providerID:result.turnID,tokens:result.tokens,status:.completed,cumulative:true,estimatedCredits:result.estimatedCredits,estimatedUSD:result.estimatedUSD,model:result.model);try Task.checkCancellation()
      }catch{self.usage.finish(operationID:operation,status:Task.isCancelled ? .cancelled:(self.usage.records.first(where:{$0.id==operation})?.tokens==nil ? .incomplete:.failed));throw error}
      consecutive=0
     }
     guard let text else{throw CheckmateError.invalid(String(localized:"translate and inspect it before recording.",bundle:.checkmate))}
     if shown(voice:false){self.inspection=([text.title]+text.teaches+text.beats.map{$0.stepTitle+"\n"+$0.say}).joined(separator:"\n\n")}
     if mode != "translate" {
      let all=mode=="preview" ? Array(text.beats.prefix(1)):text.beats,beats=all.filter{retryLast.contains(source.lessonID+":"+$0.id)==retry}
      for beat in beats {
       try Task.checkCancellation();guard !self.voiceConflict() else{throw LessonJobStopped(message:String(localized:"Recording stopped because the voice coach is active. Completed clips are kept.",bundle:.checkmate))}
       let clipNumber=(all.firstIndex{$0.id==beat.id} ?? 0)+1
       self.status=String(localized:"Lesson \(ordinal+1) of \(ordered.count), clip \(clipNumber) of \(all.count)",bundle:.checkmate)+Self.problemsSoFar(problems.count)
       do {
        if let pack=try await (Task.detached{try self.store.partialPack(source:source,locale:locale,voice:chosenVoice)}).value,let url=try await (Task.detached{try self.store.clipURL(pack:pack,beatID:beat.id)}).value {if mode=="preview",shown(voice:true){self.previewURL=url};continue}
        let operation=self.usage.begin(activity:.lessonRecording,provider:"realtime",sessionID:UUID().uuidString,model:"gpt-realtime",locale:locale,voice:chosenVoice,lessonID:source.lessonID)
        do {
         let result=try await self.recorder.record(script:beat.speak,locale:locale,voice:chosenVoice,onUsage:{[weak self] response,tokens in Task{@MainActor in self?.usage.record(operationID:operation,providerID:response,tokens:tokens,status:.running)}})
         self.usage.record(operationID:operation,providerID:result.responseID,tokens:result.tokens,status:.running,durationSeconds:Double(result.pcm.count)/48000,model:result.model)
         let pack=try await Task.detached{try self.store.saveClip(pcm:result.pcm,transcript:result.transcript,beatID:beat.id,source:source,locale:locale,voice:chosenVoice,model:result.model)}.value
         changedPacks=true;self.usage.finish(operationID:operation,status:.completed);try Task.checkCancellation();if mode=="preview",shown(voice:true){self.previewURL=try self.store.clipURL(pack:pack,beatID:beat.id)}
         consecutive=0
        }catch{self.usage.finish(operationID:operation,status:Task.isCancelled ? .cancelled:(self.usage.records.first(where:{$0.id==operation})?.tokens==nil ? .incomplete:.failed));throw error}
       }catch{try problem(source.lessonID+":"+beat.id,place+", clip \(clipNumber)",error)}
      }
     }
    }catch{try problem(source.lessonID,place,error)}
   }
   if self.generation==id{self.failedLastRun=failed}
   let moved = !shown(voice:true)
   self.status=(problems.isEmpty ? (mode=="preview" && !moved ? String(localized:"Preview ready. Choose Play Preview to listen.",bundle:.checkmate):String(localized:"Completed. Matching translated text and verified clips are reused when resuming.",bundle:.checkmate)):String(localized:"Finished with \(problems.count) problems; everything else is done and kept. Resume retries them last.",bundle:.checkmate))+(moved ? " "+String(localized:"The language or voice changed while it ran; its results are kept for the earlier choice.",bundle:.checkmate):"")
   // A job that ends early keeps this run's failures and last run's unreached ones, so Resume still tries them last.
   }catch let stop as LessonJobStopped{if self.generation==id{self.failedLastRun=failed.union(retryLast)};self.status=stop.message+(problems.isEmpty ? "":String(localized:" Problems are listed below.",bundle:.checkmate))}
   catch {if self.generation==id{self.failedLastRun=failed.union(retryLast)};self.status=Task.isCancelled ? String(localized:"Canceled. Completed text and clips are preserved.",bundle:.checkmate):userFacingMessage(error,fallback:String(localized:"The job could not finish. Completed work is preserved.",bundle:.checkmate))}
  }
 }
 public func cancel(){guard canCancel else{return};task?.cancel();status=String(localized:"Canceling…",bundle:.checkmate)}
 /// Called after Play preview starts: a preview that could not play says so instead of staying silent.
 public func reportPreviewPlayback(failure:String?){if let failure{status=failure}}
 public func remove(){guard !busy,library.lessons.indices.contains(selectedLesson) else{return};beforeRemove();previewURL=nil;let indices=allLessons ? Array(library.lessons.indices):[selectedLesson];do{for i in indices{try store.remove(source:LessonTranslation.source(library:library,index:i),locale:language,voice:voice)};status=String(localized:"Recordings removed. Translated text and lesson progress are preserved.",bundle:.checkmate);refreshStatuses(force:true);onPacksChanged()}catch{status=String(localized:"The recordings could not be removed.",bundle:.checkmate)}}
 /// Removes one recorded clip of the selected lesson, so Record / Resume re-records only that clip instead of the lesson.
 public func removeClip(step:Int){guard !busy,!allLessons,library.lessons.indices.contains(selectedLesson),library.lessons[selectedLesson].beats.indices.contains(step) else{return};beforeRemove();previewURL=nil;let source=LessonTranslation.source(library:library,index:selectedLesson);do{let removed=try store.removeClip(source:source,locale:language,voice:voice,beatID:source.beats[step].id);status=removed ? String(localized:"Clip \(step+1) removed. Record / Resume records it again; until then this lesson plays in English.",bundle:.checkmate):String(localized:"Clip \(step+1) has no stored recording.",bundle:.checkmate);selectionChanged(invalidatePreview:false);if removed{onPacksChanged()}}catch{status=String(localized:"The clip could not be removed.",bundle:.checkmate)}}
 public func discardTranslation(){guard !busy,library.lessons.indices.contains(selectedLesson) else{return};beforeRemove();previewURL=nil;let indices=allLessons ? Array(library.lessons.indices):[selectedLesson];do{for index in indices{try store.discardTranslation(source:LessonTranslation.source(library:library,index:index),locale:language)};inspection="";status=String(localized:"Translation and recordings discarded. Translate explicitly to create a replacement.",bundle:.checkmate);selectionChanged();onPacksChanged()}catch{status=String(localized:"The translation could not be discarded.",bundle:.checkmate)}}
 public func refreshAccount(){
  guard accountTask==nil else{return};accountStatus=String(localized:"Refreshing account status…",bundle:.checkmate)
  accountTask=Task{[weak self] in
   guard let self else{return};defer{self.accountTask=nil}
   let metadata=self.accountAuthMetadata
   let requestedStamp=await Task.detached{metadata?()}.value
   do {
    let text=try await self.translator.accountStatus();try Task.checkCancellation()
    self.lastAccountStatus=text;self.lastAccountRefresh=Date();self.accountAuthStamp=requestedStamp;self.accountSnapshotGeneration=UUID();self.accountSnapshotStale=false
    self.accountStatus=text+"\nRefreshed \(self.lastAccountRefresh!.formatted())"
    await self.checkAccountAuthenticationMetadata()
   }catch {
    guard !Task.isCancelled else{return}
    self.accountSnapshotStale=true;self.accountStatus=String(localized:"Account status unavailable. ",bundle:.checkmate)+userFacingMessage(error,fallback:String(localized:"Refresh explicitly after signing in.",bundle:.checkmate))
    self.appendStaleAccountSnapshot()
   }
  }
 }
 private func appendStaleAccountSnapshot(){if let previous=lastAccountStatus,let date=lastAccountRefresh{accountStatus += "\nStale account snapshot from \(date.formatted()):\n"+previous}}
 /// Read-only metadata check: never reads credentials and never contacts the provider.
 public func checkAccountAuthenticationMetadata()async {
  guard let metadata=accountAuthMetadata,let previous=accountAuthStamp,lastAccountRefresh != nil,!accountSnapshotStale else{return}
  let generation=accountSnapshotGeneration,current=await Task.detached{metadata()}.value
  guard generation==accountSnapshotGeneration,!accountSnapshotStale,current != previous else{return}
  accountSnapshotStale=true;accountStatus=String(localized:"Codex sign-in file changed. Refresh account status to confirm current limits.",bundle:.checkmate);appendStaleAccountSnapshot()
 }
 public func shutdown(){accountMonitor?.invalidate();accountMonitor=nil;task?.cancel();accountTask?.cancel();selectionTask?.cancel();statusTask?.cancel()}
}
/// Ends a lesson job outright (voice coach became active, or repeated failures): not one lesson's problem.
struct LessonJobStopped:Error,LocalizedError {let message:String;var errorDescription:String? {message}}
