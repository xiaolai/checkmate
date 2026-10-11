import Foundation
import Combine
@MainActor public final class LessonLanguageController:ObservableObject {
 public let library:CourseLibrary,store:LessonPackStore,usage:UsageLedger
 @Published public var language="en" {didSet{if oldValue != language{selectionChanged()}}}
 @Published public var voice="cedar" {didSet{if oldValue != voice{selectionChanged()}}}
 @Published public var selectedLesson=0 {didSet{if oldValue != selectedLesson{selectionChanged()}}}
 @Published public var allLessons=false
 @Published public private(set) var busy=false
 @Published public private(set) var status="Select a language, then translate a lesson."
 @Published public private(set) var inspection=""
 @Published public private(set) var previewURL:URL?
 @Published public private(set) var storedStatus="No stored recordings for this selection."
 @Published public private(set) var accountStatus="Account status has not been refreshed. Voice subscription attribution is unknown."
 public var voiceConflict:()->Bool={false},beforeRemove:()->Void={},playPreview:((URL)->Void)?,onPacksChanged:()->Void={},onSelectionChange:()->Void={}
 public private(set) var recording=false
 private let translator:any LessonTranslationProvider,recorder:any LessonRecordingProvider
 private var task:Task<Void,Never>?,generation=UUID(),accountTask:Task<Void,Never>?
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
 public init(library:CourseLibrary,directory:URL,usage:UsageLedger,translator:any LessonTranslationProvider=CodexSubscriptionClient(),recorder:any LessonRecordingProvider=RealtimeLessonRecorder(),accountAuthMetadata:(@Sendable ()->String)?=nil)throws {self.library=library;do{store=try LessonPackStore(directory:directory)}catch{store=LessonPackStore.unavailable(directory:directory,reason:"Offline lesson storage is unavailable. English lessons remain available.")};self.usage=usage;self.translator=translator;self.recorder=recorder
  if let accountAuthMetadata{self.accountAuthMetadata=accountAuthMetadata}else if !NativePolicy.silent,translator is CodexSubscriptionClient{self.accountAuthMetadata={Self.liveAuthMetadata()}}else{self.accountAuthMetadata=nil}
  if !NativePolicy.silent,self.accountAuthMetadata != nil {
   accountMonitor=Timer.scheduledTimer(withTimeInterval:3,repeats:true){[weak self] _ in Task{@MainActor in await self?.checkAccountAuthenticationMetadata()}}
  }
  let store=self.store;if let problem=store.unavailableReason{status=problem}else{Task.detached{try? store.sweepStale(library:library)}}}
 private func selectionChanged(invalidatePreview:Bool=true){if invalidatePreview{previewURL=nil;inspection="";storedStatus="Checking stored lesson data…";onSelectionChange()};selectionTask?.cancel();selectionGeneration=UUID();let generation=selectionGeneration;guard !busy,library.lessons.indices.contains(selectedLesson) else{return};let source=LessonTranslation.source(library:library,index:selectedLesson),locale=language,voice=self.voice,store=self.store;selectionTask=Task{[weak self] in
   let result=await Task.detached{()->(String,String) in do{guard let translation=try store.translation(source:source,locale:locale) else{return ("","No translated text or recordings for this selection.")};let text=([translation.title]+translation.teaches+translation.beats.map{$0.stepTitle+"\n"+$0.say}).joined(separator:"\n\n");if let pack=try store.completePack(source:source,locale:locale,voice:voice){return (text,"Complete offline lesson: \(pack.clips.count) verified recordings.")};let count=(try store.partialPack(source:source,locale:locale,voice:voice))?.clips.count ?? 0;return (text,"Translated text stored; \(count) of \(source.beats.count) recordings stored. Incomplete lessons use English.")}catch{return ("","Stored lesson data is unavailable or invalid. Remove its recordings to retry.")}}.value
   guard let self,!Task.isCancelled,self.selectionGeneration==generation,!self.busy else{return};self.inspection=result.0;self.storedStatus=result.1
 }}
 public func translate(){start(mode:"translate")}
 public func record(){start(mode:"record")}
 public func preview(){start(mode:"preview")}
 private func start(mode:String) {
  if let problem=store.unavailableReason{status=problem;return}
  guard !busy,LessonLanguages.valid(language),language != "en",library.lessons.indices.contains(selectedLesson),["cedar","marin"].contains(voice) else{status="Choose a supported language and lesson first.";return}
  if mode != "translate",voiceConflict(){status="Disconnect the voice coach before generating lesson recordings.";return}
  let locale=language,chosenVoice=voice,indices=allLessons && mode != "preview" ? Array(library.lessons.indices):[selectedLesson],id=UUID();generation=id;busy=true;recording=mode != "translate";previewURL=nil
  task=Task{[weak self] in
   guard let self else{return};var changedPacks=false;defer{if self.generation==id{self.busy=false;self.recording=false;self.task=nil;self.selectionChanged(invalidatePreview:false);if changedPacks{self.onPacksChanged()}}}
   do {for (ordinal,index) in indices.enumerated() {
    try Task.checkCancellation();let source=LessonTranslation.source(library:self.library,index:index)
    self.status="Lesson \(ordinal+1) of \(indices.count): \(mode == "translate" ? "translating":"recording")"
    var text=try await Task.detached{try self.store.translation(source:source,locale:locale)}.value
    if mode=="translate",text==nil {
     let operation=self.usage.begin(activity:.translation,provider:"codex",sessionID:UUID().uuidString,locale:locale,lessonID:source.lessonID)
     do {
      let result=try await self.translator.translate(source:source,locale:locale,onUsage:{[weak self] turn,model,tokens in Task{@MainActor in self?.usage.record(operationID:operation,providerID:turn,tokens:tokens,status:.running,cumulative:true,model:model)}})
      self.usage.record(operationID:operation,providerID:result.turnID,tokens:result.tokens,status:.running,cumulative:true,estimatedCredits:result.estimatedCredits,estimatedUSD:result.estimatedUSD,model:result.model)
      try await Task.detached{try self.store.saveTranslation(result.text,source:source,locale:locale)}.value;text=result.text
      self.usage.record(operationID:operation,providerID:result.turnID,tokens:result.tokens,status:.completed,cumulative:true,estimatedCredits:result.estimatedCredits,estimatedUSD:result.estimatedUSD,model:result.model);try Task.checkCancellation()
     }catch{self.usage.finish(operationID:operation,status:Task.isCancelled ? .cancelled:(self.usage.records.first(where:{$0.id==operation})?.tokens==nil ? .incomplete:.failed));throw error}
    }
    guard let text else{throw CheckmateError.invalid("Translate and inspect this lesson before recording.")}
    self.inspection=([text.title]+text.teaches+text.beats.map{$0.stepTitle+"\n"+$0.say}).joined(separator:"\n\n")
    if mode != "translate" {
     let beats=mode=="preview" ? Array(text.beats.prefix(1)):text.beats
     for (clipIndex,beat) in beats.enumerated() {
      try Task.checkCancellation();guard !self.voiceConflict() else{throw CheckmateError.unavailable("Recording stopped because the voice coach is active.")}
      self.status="Lesson \(ordinal+1) of \(indices.count), clip \(clipIndex+1) of \(beats.count)"
      if let pack=try await Task.detached{try self.store.partialPack(source:source,locale:locale,voice:chosenVoice)}.value,let url=try await Task.detached{try self.store.clipURL(pack:pack,beatID:beat.id)}.value {if mode=="preview"{self.previewURL=url};continue}
      let operation=self.usage.begin(activity:.lessonRecording,provider:"realtime",sessionID:UUID().uuidString,model:"gpt-realtime",locale:locale,voice:chosenVoice,lessonID:source.lessonID)
      do {
       let result=try await self.recorder.record(script:beat.speak,locale:locale,voice:chosenVoice,onUsage:{[weak self] response,tokens in Task{@MainActor in self?.usage.record(operationID:operation,providerID:response,tokens:tokens,status:.running)}})
       self.usage.record(operationID:operation,providerID:result.responseID,tokens:result.tokens,status:.running,durationSeconds:Double(result.pcm.count)/48000,model:result.model)
       let pack=try await Task.detached{try self.store.saveClip(pcm:result.pcm,transcript:result.transcript,beatID:beat.id,source:source,locale:locale,voice:chosenVoice,model:result.model)}.value
       changedPacks=true;self.usage.finish(operationID:operation,status:.completed);try Task.checkCancellation();if mode=="preview"{self.previewURL=try self.store.clipURL(pack:pack,beatID:beat.id)}
      }catch{self.usage.finish(operationID:operation,status:Task.isCancelled ? .cancelled:(self.usage.records.first(where:{$0.id==operation})?.tokens==nil ? .incomplete:.failed));throw error}
     }
    }
   };self.status=mode=="preview" ? "Preview ready. Choose Play preview to listen.":"Completed. Matching translated text and verified clips are reused when resuming."
   }catch {self.status=Task.isCancelled ? "Cancelled. Completed text and clips are preserved.":userFacingMessage(error,fallback:"The job could not finish. Completed work is preserved.")}
  }
 }
 public func cancel(){task?.cancel();status="Cancelling…"}
 public func remove(){guard !busy,library.lessons.indices.contains(selectedLesson) else{return};beforeRemove();previewURL=nil;let indices=allLessons ? Array(library.lessons.indices):[selectedLesson];do{for i in indices{try store.remove(source:LessonTranslation.source(library:library,index:i),locale:language,voice:voice)};status="Recordings removed. Translated text and lesson progress are preserved.";onPacksChanged()}catch{status="The recordings could not be removed."}}
 public func discardTranslation(){guard !busy,library.lessons.indices.contains(selectedLesson) else{return};beforeRemove();previewURL=nil;let indices=allLessons ? Array(library.lessons.indices):[selectedLesson];do{for index in indices{try store.discardTranslation(source:LessonTranslation.source(library:library,index:index),locale:language)};inspection="";status="Translation and recordings discarded. Translate explicitly to create a replacement.";selectionChanged();onPacksChanged()}catch{status="The translation could not be discarded."}}
 public func refreshAccount(){
  guard accountTask==nil else{return};accountStatus="Refreshing account status…"
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
    self.accountSnapshotStale=true;self.accountStatus="Account status unavailable. Refresh explicitly after signing in."
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
  accountSnapshotStale=true;accountStatus="Codex sign-in file changed. Refresh account status to confirm current limits.";appendStaleAccountSnapshot()
 }
 public func shutdown(){accountMonitor?.invalidate();accountMonitor=nil;task?.cancel();accountTask?.cancel();selectionTask?.cancel()}
}
