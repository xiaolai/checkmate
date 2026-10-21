import AppKit
import UniformTypeIdentifiers
import Combine
import CheckmateCore
import RealtimeConnection
@MainActor final class NativeModel:ObservableObject {
    let session:GameSession,learning:LearningPlayer,audio:NativeAudio,store:StateStore
    let companion:CompanionBroker,voice:VoiceCoach
    let voicePreview=VoicePreview()
    let usage:UsageLedger,lessonLanguages:LessonLanguageController
    let review=ReviewController()
    /// The training library and its exercises; nil while training is not enabled for this build (plan: rollout flag).
    let training:TrainingController?
    /// The voice coach's door into a standard-rule training game (mini-game plan WI-021); nil unless its flag is on.
    let trainingVoice:TrainingVoiceAdapter?
    let reviewStore:ReviewStore,reviewAnalyzer:ReviewAnalyzer
    /// The network-game fairness check every engine and voice component shares (LAN-play plan D8), and the network game.
    let fairness:FairnessPolicy,network:NetworkGameController
    /// The network game's own hints, under its agreed terms (assistance plan A8).
    let networkAssistant:NetworkAssistant
    @Published var reviews:[ReviewIndexEntry]=[]
    /// The review workspace and a draft review are part of the session's activity (B8.2), not flags of their own.
    var reviewWorkspace:Bool {session.activity.inReviewWorkspace}
    var reviewDraft:Bool {session.activity.review?.draft ?? false}
    @Published private(set) var deletingReviewID:UUID?
    private var reviewLibraryGeneration=0
    @Published var importingReview=false
    @Published var practiceForkRequested=false
    private var reviewImportTask:Task<Void,Never>?
    private var reviewImportCancellation:ReviewImportCancellation?
    private struct ReviewSnapshot:Equatable {let document:GameDocument,cursor:Int,branches:[ReviewBranch]}
    /// Unsaved review state per record. A failed save stays here (and its warning stays visible) until a later save
    /// of that record succeeds; opening or saving another review never replaces it.
    private var pendingReviewSnapshots:[UUID:ReviewSnapshot]=[:]
    private var writtenReviewSnapshots:[UUID:ReviewSnapshot]=[:]
    /// Whether a save of this review is still queued or failed (its in-memory state is newer than its file).
    func reviewSavePending(_ id:UUID)->Bool {pendingReviewSnapshots[id] != nil}
    /// The review-save warning currently shown, so only a review save's own success clears it.
    private var reviewSaveWarning:String?
    private var reviewSaveGeneration=0
    private var reviewOpenGeneration=0
    var automationReviewLoadDelayMs=0
    var automationReviewImportDelayMs=0
    private var restoringReview=false
    private let reviewSaves:ReviewSaveCoordinator
    private static func reviewSaveFailure(_ error:Error)->String {
        let reason=userFacingMessage(error,fallback:"")
        return reason.isEmpty ? String(localized:"The review could not be saved. Export the original PGN before quitting.",bundle:.checkmate):String(localized:"The review could not be saved: \(reason.trimmingCharacters(in:CharacterSet(charactersIn:"."))). Export the original PGN before quitting.",bundle:.checkmate)
    }
    private var reviewSaveTask:Task<Void,Never>?
    private static let progressSaveFailure=String(localized:"Your progress could not be saved. Export it before quitting.",bundle:.checkmate)
    private var shuttingDown=false
    private var connectionStartup:ConnectionStartup<ClientSecret>?
    /// Which Checkmate Codex starts for chess MCP, read from Codex's configuration at launch and after Set up Codex
    /// (V-15); nil until read, and never read during automation.
    @Published private(set) var codexSetup:CompanionInstallation.SetupCheck?
    /// This copy's MCP executable, which Set up Codex registers.
    static var mcpExecutable:URL? {Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("CheckmateMCP")}
    /// Reads Codex's configuration again, without running Codex.
    func refreshCodexSetup(){guard !NativePolicy.silent,let executable=Self.mcpExecutable else{return};codexSetup=CompanionInstallation.setupCheck(executable:executable)}
    var onReview:(()->Void)?
    /// True for a move the learner dropped in place: it does not animate, so its sound does not wait for one.
    var movePlacedDirectly:((MoveRecord)->Bool)?
    @Published var storageError:String?
    var onImport:(()->Void)?
    private var saveTask:Task<Void,Never>?
    private var soundTasks:[UUID:Task<Void,Never>]=[:]
    private var observations:Set<AnyCancellable>=[]
    private var reviewTools:ReviewTools!
    /// Changes whenever the user chooses another activity or review source; stale completions compare it.
    var activityGeneration:Int {reviewOpenGeneration}
    func dismissStorageError(){storageError=nil}
    /// True only while the session holds a practice reply after a failed saved-review restore. The session owns the
    /// gate (every reply entry point respects it); the banner, practice pane and bottom transport offer the explicit
    /// "Return to Game"/"Resume Game" action. A new game, restore, import, fork or lesson clears it with the position.
    var restoreResumePending:Bool {session.explicitResumeRequired}
    static let failedRestoreMessage=String(localized:"The saved review could not be restored; its file is preserved.",bundle:.checkmate)
    static let failedRestorePausedMessage=Sentences.join(failedRestoreMessage,String(localized:"Your game is paused. Choose Return to Game to continue.",bundle:.checkmate))
    func resumeAfterFailedRestore(){storageError=nil;practice()}
    init() throws {
        if !NativePolicy.silent {Task.detached{CodexSubscriptionClient.cleanAbandonedPrivateHomes()}}
        store=StateStore(directory:StateStore.defaultDirectory());let state=try store.load();store.preserveFirstLaunchBackup()
        // One fairness check for every component that can reach the engine or the voice coach (LAN-play plan D8).
        let engine=NativeEngine(),fairness=FairnessPolicy();self.fairness=fairness;reviewAnalyzer=ReviewAnalyzer(engine:engine,cacheDirectory:store.directory.appendingPathComponent("ReviewAnalysis"),fairness:fairness);reviewStore=ReviewStore(directory:store.directory.appendingPathComponent("Reviews"))
        reviewSaves=ReviewSaveCoordinator(store:reviewStore)
        session=try GameSession(engine:engine,state:state,fairness:fairness);review.fairness=fairness;review.analyzer=reviewAnalyzer;network=try NetworkGameController(services:Self.networkServices(directory:store.directory),participation:fairness.participation,playerName:Self.defaultPlayerName);session.network=network;networkAssistant=NetworkAssistant(game:network,fairness:fairness,engine:engine);learning=try LearningPlayer(session:session);audio=NativeAudio(scores:learning.library.sounds);learning.audio=audio
        training=TrainingRolloutPolicy.enabled ? TrainingController(session:session,learning:learning):nil;training?.games.engine=engine;training?.games.fairness=fairness
        if TrainingRolloutPolicy.trainingVoiceEnabled,let training{trainingVoice=TrainingVoiceAdapter(session:session,controller:training)}else{trainingVoice=nil}
        companion=try CompanionBroker(session:session,directory:store.directory.appendingPathComponent("companion"));voice=try VoiceCoach(session:session)
        usage=UsageLedger(directory:store.directory.appendingPathComponent("Usage"))
        if NativePolicy.silent,ProcessInfo.processInfo.environment["CHECKMATE_LESSON_FIXTURE"]=="1" {
            lessonLanguages=try LessonLanguageController(library:learning.library,directory:store.directory,usage:usage,translator:LessonAutomationTranslator(),recorder:LessonAutomationRecorder())
            lessonLanguages.cleanupPause = .seconds(2)
        } else {
            lessonLanguages=try LessonLanguageController(library:learning.library,directory:store.directory,usage:usage)
        }
        lessonLanguages.language=state.settings.lessonLanguage;lessonLanguages.voice=state.settings.lessonVoice
        // A deleted review keeps its engine analysis while it waits in the Trash (so Undo brings both back); the analysis
        // goes when the Trash lets the review go. A failure only leaves files for LRU eviction.
        // A review Undo offers to put back that the Trash let go (to make room) can no longer come back: Undo stops offering it.
        reviewStore.onPurge={[weak self] id in Task{@MainActor in if self?.undoableDeletion?.id==id{self?.undoableDeletion=nil};do{try await self?.reviewAnalyzer.forgetAnalysis(documentID:id)}catch{NativeLog.storage.error("A purged review's analysis could not be removed: \(String(describing:error),privacy:.public)")}}}
        wireLessonLanguages();wireAgentTools();wirePersistence();wireSounds();loadSavedReviews();observeSession()
        voiceHelp.attach(self)
        // Views that hide engine output during a network game redraw when it begins or ends; a practice coach that
        // waited out the game (D8) reconnects once it ends, if Practice is on screen then.
        fairness.participation.observe{[weak self] role in self?.objectWillChange.send();if role==nil{DispatchQueue.main.async{self?.resumeVoiceIfIntended()}}}
        // Whose conversation the coach's history is: it is cleared whenever the coach opens for another one (practice,
        // or another network game), so the game it last opened for, however it was connected, owns what it holds.
        voice.$connection.filter{$0 == .ready}.sink{[weak self] _ in guard let self else{return};self.networkVoiceGame=self.voice.networkSession ? self.network.record?.gameID:nil}.store(in:&observations)
        // The lobby browses only while the network place is on screen (D1); the game itself carries on elsewhere (D9).
        session.$activity.removeDuplicates().sink{[weak self] activity in self?.network.setShown(activity == .at(.network))}.store(in:&observations)
        // A host whose Mac sleeps stops its game as interrupted (D9).
        // NSWorkspace posts these on the main thread; handling them there, not a hop later, gets the farewell queued
        // before the Mac sleeps.
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.willSleepNotification).sink{[weak self] _ in MainActor.assumeIsolated{self?.network.systemWillSleep()}}.store(in:&observations)
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didWakeNotification).sink{[weak self] _ in MainActor.assumeIsolated{self?.network.systemDidWake()}}.store(in:&observations)
    }
    /// Answers "Leave the game? It counts as a resignation." and "Resign this game?" (D9). Tests inject an answer;
    /// otherwise the learner is asked.
    var confirmLeavingNetworkGame:(()->Bool)?
    var confirmResigningNetworkGame:(()->Bool)?
    /// How often the permission help's button asked for System Settings (D11); automation counts instead of opening it.
    var networkSettingsRequests=0
    /// Lesson languages share the one narration channel and the voice coach's connection.
    private func wireLessonLanguages(){
        learning.packs=lessonLanguages.store;voice.usageLedger=usage;voice.network=(network,networkAssistant);voice.training=trainingVoice;voice.connectionBlocked={[weak self] in self?.lessonLanguages.recording==true || self?.audio.isNarrationPlaying==true || self?.voicePreview.playing==true}
        voice.connectionBlockReason={[weak self] in self?.lessonLanguages.recording==true ? .lessonRecording:self?.voicePreview.playing==true ? .previewPlaying:.narrationPlaying}
        reconnectVoice={[weak self] in self?.voice.connect(greet:false)}
        voicePreview.usageLedger=usage;voicePreview.consented={[weak self] in self?.session.state.settings.voiceConsent==true};voicePreview.onPlayingChanged={[weak self] playing in self?.voice.externalPlayback=playing}
        // Whatever else plays waits for its turn: a preview blocks connecting, and lesson playback ends a preview.
        lessonLanguages.objectWillChange.sink{[weak self] in DispatchQueue.main.async{self?.resumeVoiceIfIntended()}}.store(in:&observations)
        learning.$playing.filter{$0}.sink{[weak self] _ in self?.voicePreview.cancel()}.store(in:&observations)
        audio.onNarrationStart={[weak self] in self?.voicePreview.cancel()}
        voicePreview.$playing.removeDuplicates().filter{!$0}.dropFirst().sink{[weak self] _ in DispatchQueue.main.async{self?.resumeVoiceIfIntended()}}.store(in:&observations)
        voicePreview.blocked={[weak self] in guard let self else{return nil};if voice.canStopTurn{return String(localized:"Wait until the coach finishes speaking, then preview.",bundle:.checkmate)};if lessonLanguages.recording{return String(localized:"Finish or cancel lesson recording before previewing a voice.",bundle:.checkmate)};if audio.isNarrationPlaying{return String(localized:"Stop lesson playback before previewing a voice.",bundle:.checkmate)};return nil}
        lessonLanguages.voiceConflict={[weak self] in self?.voice.connected==true || self?.voice.connecting==true}
        // Settings effects are not navigation (LE-5): the Lesson picker only stops a preview of the old selection; a preview
        // or a removal stops lesson narration (one narration channel) but never a mini-game's pending computer reply.
        lessonLanguages.onSelectionChange={[weak self] in guard let self,!self.learning.playing else{return};self.audio.stop()};lessonLanguages.onPacksChanged={[weak self] in self?.learning.reloadLocalizedPacks()};lessonLanguages.beforeRemove={[weak self] in guard let self else{return};if self.lessonLanguages.allLessons || self.lessonLanguages.selectedLesson==self.learning.lessonIndex{self.learning.pauseNarration();self.audio.stop()}else if !self.learning.playing{self.audio.stop()}}
        lessonLanguages.playPreview={[weak self] url in guard let self else{return};self.learning.pauseNarration();self.audio.play(localURL:url,seconds:0,settings:self.session.state.settings);self.lessonLanguages.reportPreviewPlayback(failure:self.audio.narrationFailure)}
    }
    /// The review and training tools agents call, and when an agent may open a review.
    private func wireAgentTools(){
        session.reviewController=review;voice.attachReview(review);voice.attachMiniReview(learning.miniReview)
        let reviewTools=ReviewTools(review:review,session:session,store:reviewStore,analyzer:reviewAnalyzer);reviewTools.onOpen={[weak self] document,saved in self?.openReview(document,saved:saved,stillWanted:{!Task.isCancelled}) ?? false};reviewTools.onPractice={[weak self] in self?.practiceFromReview()};companion.tools.reviewTools=reviewTools;self.reviewTools=reviewTools
        reviewTools.activityGeneration={[weak self] in self?.reviewOpenGeneration ?? -1}
        if let training{let tools=TrainingTools(session:session,controller:training);tools.onStart={[weak self] entry,resume in guard let self else{return false};let kind=training.catalog?.entry(entry)?.legacyKind;let next:Navigation=resume ? .trainingResume:kind.map{.trainingLegacy($0,restart:false)} ?? .trainingExercise(entry:entry);return self.navigate(next)};companion.tools.trainingTools=tools}
        companion.tools.reviewOpenAllowed={[weak self] in guard let self else{return false};return self.reviewWorkspace || self.review.active}
    }
    /// Progress saves debounced off every change, and the open review saves on each of its events.
    private func wirePersistence(){
        session.onPersist={[weak self] state in guard let self=self else{return};self.saveTask?.cancel();self.saveTask=Task{try? await Task.sleep(nanoseconds:250_000_000);guard !Task.isCancelled else{return};do{try self.store.save(state);if self.storageError==Self.progressSaveFailure{self.storageError=nil}}catch{NativeLog.storage.error("State save failed; export remains available");self.storageError=Self.progressSaveFailure}}}
        review.onEvent={[weak self] in self?.session.signalEvent();self?.saveReview()}
    }
    /// Move, illustration and undo sounds; a move's sound waits for its animation.
    private func wireSounds(){
        learning.onIllustration={[weak self] piece,capture in guard let self=self else{return};self.audio.illustration(piece:piece,capture:capture,settings:self.session.state.settings)}
        session.onMove={[weak self] move in guard let self=self else{return};let settings=self.session.state.settings;let delay=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || self.movePlacedDirectly?(move)==true ? 0:settings.pieceDuration;let id=UUID();self.soundTasks[id]=Task{defer{self.soundTasks.removeValue(forKey:id)};try? await Task.sleep(nanoseconds:UInt64(delay)*1_000_000);guard !Task.isCancelled else{return};self.audio.move(move,settings:settings)}}
        learning.onMiniMove=session.onMove
        learning.onAttemptMove=session.onMove
        training?.onMove=session.onMove
        learning.onAttemptReset={[weak self] in self?.cancelMoveSounds()}
        learning.onMiniReset={[weak self] in self?.cancelMoveSounds()}
        session.onUndo={[weak self] in guard let self=self else{return};self.cancelMoveSounds();self.audio.move(nil,settings:self.session.state.settings,undo:true)}
    }
    /// The saved-review library loads off the main thread; a library changed meanwhile wins.
    private func loadSavedReviews(){
        let reviewStore=reviewStore;Task{do{let (entries,moved)=try await Task.detached{let entries=try reviewStore.list();return (entries,reviewStore.takeQuarantinedCount())}.value
            if moved>0{storageError=String(localized:"\(moved) saved reviews could not be read and were moved to the Quarantine folder inside Reviews. Nothing was deleted.",bundle:.checkmate)}
            guard reviewLibraryGeneration==0 else{return};reviews=entries}catch{storageError=String(localized:"Saved reviews could not be loaded. Your current practice is unchanged.",bundle:.checkmate)}}
    }
    /// Views observe this model: forward training, activity, resume-gate and settings changes.
    private func observeSession(){
        // Anything else Undo owns drops a pending deletion's Undo as it happens, so coming back to the same board
        // cannot revive it. Published before the change: compare on the next main-loop turn.
        let changes:[AnyPublisher<Void,Never>]=[session.objectWillChange.map{_ in}.eraseToAnyPublisher(),review.objectWillChange.map{_ in}.eraseToAnyPublisher(),learning.objectWillChange.map{_ in}.eraseToAnyPublisher()]+(training.map{[$0.objectWillChange.map{_ in}.eraseToAnyPublisher()]} ?? [])
        Publishers.MergeMany(changes).sink{[weak self] in guard self?.undoableDeletion != nil else{return};DispatchQueue.main.async{_ = self?.undoAction}}.store(in:&observations)
        training?.objectWillChange.sink{[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        // The workspace and draft flags read the session's activity; views observing this model follow it.
        session.$activity.removeDuplicates().dropFirst().sink{[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        // Published before it changes: read the new activity on the next main-loop turn.
        session.$activity.removeDuplicates().dropFirst().sink{[weak self] _ in DispatchQueue.main.async{self?.resumeVoiceIfIntended()}}.store(in:&observations)
        // The banner observes this model; forward gate changes, and drop the paused sentence once the held game resumed or changed.
        session.$explicitResumeRequired.removeDuplicates().dropFirst().receive(on:RunLoop.main).sink{[weak self] held in guard let self=self else{return};self.objectWillChange.send();if !held,self.storageError==Self.failedRestorePausedMessage{self.storageError=Self.failedRestoreMessage}}.store(in:&observations)
        session.$state.map(\.settings).removeDuplicates().dropFirst().receive(on:RunLoop.main).sink {[weak self] _ in guard let self else{return};self.syncLessonSelection();self.learning.settingsChanged();self.voice.settingsChanged()}.store(in:&observations)
        // A running lesson job keeps the language and voice it started with; the selection follows settings once it ends.
        lessonLanguages.$busy.removeDuplicates().filter{!$0}.receive(on:RunLoop.main).sink{[weak self] _ in self?.syncLessonSelection()}.store(in:&observations)
    }
    /// The launch attempt waited while the app was hidden (Cmd-H during the check, or launched hidden); run it now.
    func resumeConnectionsIfDeferred(){connectionStartup?.resumeIfDeferred()}
    /// Voice may take the session only in practice itself: never in a lesson, puzzle, review or the review workspace (TX-3),
    /// and never during a network game (D8). A coach for the network game is opened on its own page (assistance plan
    /// A10); connecting from Practice then would open that one, so a practice session's resume waits for the game's end.
    var voiceMayConnect:Bool {session.activity == .at(.practice) && !session.suspended && fairness.engineHelpAllowed}
    /// Away: the app hidden or its window minimised (TX-5). Agents and Stockfish wait, voice disconnects; on return the
    /// connection resumes and a launch check that waited runs.
    private(set) var away=false
    func setAway(_ value:Bool){guard value != away else{return};away=value
        // The session itself holds play, with or without the MCP broker; voice disconnects only once play is held.
        if companion.enabled{companion.suspend(value)}else{session.setConnection(enabled:false,role:session.companionRole,suspended:value)}
        if value{rememberVoice();voice.disconnect();voicePreview.cancel()}else{resumeConnectionsIfDeferred();resumeVoiceIfIntended()}}
    /// D2: voice the learner had connected when it left Practice (or the app went away) reconnects when Practice is
    /// visible again, without a new greeting. Leaving while voice was off, or an MCP companion taking the session,
    /// leaves it off.
    private(set) var voiceResumeIntent=false
    /// The network game the coach last opened for, or nil when it last opened for Practice (A10).
    private var networkVoiceGame:NetworkGameID?
    /// The network page shows only what this game's coach said: never Practice's conversation or an earlier game's. A
    /// renewed or reconnected session in the same game keeps it, whether it was connected here or from Settings.
    var networkVoiceHistory:[VoiceHistory] {
        guard let game=network.record?.gameID,networkVoiceGame==game else{return []}
        return voice.history
    }
    /// The network page's Connect Voice Coach.
    func connectNetworkVoice(){connectVoiceWithConsent{[weak self] in self?.voice.connect()}}
    /// The control bar's Connect: the training game's coach in Training, otherwise Practice's (or a review's).
    func connectPracticeVoice(){connectVoiceWithConsent{[weak self] in guard let self else{return};if session.mode == .training{voice.connectTraining()}else{voice.connect()}}}
    /// Settings ▸ Voice Coach's Connect, and a review's Connect Voice.
    func connectVoiceFromSettings(){connectVoiceWithConsent{[weak self] in self?.voice.connect()}}
    /// A finished mini-game review's Read Aloud (D5), with the sign-in check it may need, Check availability and Preview
    /// voice reach OpenAI too, so they ask the same question first.
    func readMiniReviewAloud(){connectVoiceWithConsent{[weak self] in self?.voice.readMiniReviewAloudAfterSignIn()}}
    func checkVoiceAvailability(){connectVoiceWithConsent{[weak self] in self?.voice.checkAvailability()}}
    /// The selected voice is heard in its own preview session, never through the coach's conversation; a second press stops it.
    func previewVoice(){
        if voicePreview.playing{voicePreview.cancel();return}
        connectVoiceWithConsent{[weak self] in
            guard let self else{return};let settings=session.state.settings
            voicePreview.play(voice:settings.coachVoice,language:AppSettings.languages[settings.voiceLanguage] ?? String(localized:"English",bundle:.checkmate),model:voice.selectedModel.isEmpty ? VoiceSessionConfiguration.model:voice.selectedModel,volume:settings.voiceVolume)
        }
    }
    /// Asks the learner, with the saved launch choice as the checkbox's start, whether to connect voice (V-1). Tests
    /// answer instead; the app shows `VoiceConsent`'s sheet.
    var askVoiceConsent:(_ autoConnect:Bool,_ reply:@escaping (VoiceConsentAnswer)->Void)->Void={autoConnect,reply in VoiceConsent.ask(autoConnect:autoConnect,reply:reply)}
    private var askingVoiceConsent=false
    /// Every Connect the learner presses, and every other press that reaches OpenAI, passes here. Until they have agreed once to what voice sends to OpenAI, the
    /// question comes first; Connect saves the agreement (and the launch choice) before connecting, Cancel changes
    /// nothing. Automatic connections never ask: they never run without the saved agreement.
    func connectVoiceWithConsent(_ connect:@escaping ()->Void){
        guard !session.state.settings.voiceConsent else{connect();return}
        guard !askingVoiceConsent else{return}
        askingVoiceConsent=true
        askVoiceConsent(session.state.settings.voiceAutoConnect){[weak self] answer in
            guard let self else{return};askingVoiceConsent=false
            guard case .connect(let autoConnect)=answer else{return}
            var settings=session.state.settings;settings.voiceConsent=true;settings.voiceAutoConnect=autoConnect;session.updateSettings(settings)
            connect()
        }
    }
    /// The typed question, failure actions, capability check and announcements around the coach (V-3, V-5, V-6, V-21).
    let voiceHelp=VoiceHelp()
    var reconnectVoice:()->Void={}
    private var claimsWhenVoiceLeft=0
    private func rememberVoice(){if !voice.networkSession,voice.miniReviewSession==nil,!voice.trainingSession,voice.connected || voice.connecting{voiceResumeIntent=true;claimsWhenVoiceLeft=session.companionClaims}}
    func resumeVoiceIfIntended(){
        guard voiceResumeIntent,!away,!shuttingDown,voiceMayConnect else{return}
        if session.companionEnabled || session.companionClaims != claimsWhenVoiceLeft{voiceResumeIntent=false;return}
        // A recording or narration that blocks connecting keeps the intent; its end tries again.
        guard !voice.connectionBlocked(),!voicePreview.playing else{return}
        voiceResumeIntent=false
        guard !voice.connected,!voice.connecting else{return}
        reconnectVoice()
    }
    private func syncLessonSelection(){guard !lessonLanguages.busy else{return};lessonLanguages.language=session.state.settings.lessonLanguage;lessonLanguages.voice=session.state.settings.lessonVoice}
    func startConnections(){
        guard connectionStartup==nil,!NativePolicy.silent else{return}
        // Voice is judged by its own and the activity's generations (connectVoice); the broker's generation, which its
        // own start or an asynchronous listener failure moves, only decides whether MCP still starts.
        let activity=activityGeneration,voiceGeneration=voice.connectionGeneration,brokerGeneration=companion.connectionGeneration
        refreshCodexSetup()
        connectionStartup=ConnectionStartup(
            settings:{[weak self] in self?.session.state.settings ?? AppSettings()},
            // Voice needs only the Codex sign-in, not the Codex command; the MCP broker below still needs the command.
            check:{[weak self] in guard let self else{return nil}
                // A manual Check availability replaces this check; follow it instead of reading its cancellation as "unavailable".
                var check=voice.checkAvailability()
                while true{let secret=await check.value;if secret != nil{return secret};guard let newer=voice.currentAvailabilityCheck,newer != check else{return nil};check=newer}
            },
            connectVoice:{[weak self] authorization in
                guard let self,activityGeneration==activity,voice.connectionGeneration==voiceGeneration,voiceMayConnect else{return}
                voice.connect(authorizedSecret:authorization)
            },
            // A failed start has already stopped the broker and shows its error in Settings ▸ Connections.
            startMCP:{[weak self] in
                guard let self,companion.connectionGeneration==brokerGeneration else{return}
                try companion.enable(role:session.state.settings.companionRole,standby:true)
            },
            // Only a Codex that Set up Codex registered can use chess MCP, so without it nothing listens.
            codexSetUp:{[weak self] in self?.codexSetup?.registered==true},
            stillCurrent:{[weak self] in
                guard let self else{return false}
                return !shuttingDown
            },
            visible:{[weak self] in guard let self else{return false};return !NSApp.isHidden && !session.suspended})
        connectionStartup?.start()
    }
    /// Sidebar Practice a game. A review opened over practice returns to it exactly as Return to game does (a Try a
    /// move or demonstration is kept, TX-8); from anywhere else the game is shown.
    func practice(){navigate(.practice)}
    func lesson(_ index:Int){navigate(.lesson(index))}
    /// A mini-game from the sidebar (L-33): it opens from its lesson, exactly as the lesson's own Play button does.
    func playMiniGame(_ kind:MiniGameKind){
        guard let index=SidebarSelection.miniGames(learning.library).first(where:{$0.kind==kind})?.lesson,navigate(.lesson(index)) else{return}
        learning.startMini(kind)
    }
    func puzzles(){navigate(.puzzles)}
    /// A lesson's Check Yourself: its own puzzles, when the puzzles may be opened now.
    func checkYourself(_ index:Int){if navigate(.puzzles){learning.checkYourself(index:index)}}
    func trainingLibrary(){navigate(.trainingLibrary)}
    func playOnNetwork(){navigate(.network)}
    /// A new exercise, the saved unfinished one, or an existing mini-game; a failure is shown and nothing changes.
    func startTraining(_ entry:String,variant:String?=nil){navigate(.trainingExercise(entry:entry,variant:variant))}
    func startTrainingScenario(_ id:String){navigate(.trainingScenario(id:id))}
    func openTrainingLesson(_ id:String){navigate(.trainingLesson(id:id))}
    func resumeTraining(){navigate(.trainingResume)}
    func retryTraining(_ id:String){navigate(.trainingRetry(id:id))}
    func playTrainingGame(_ kind:MiniGameKind,restart:Bool=false){navigate(.trainingLegacy(kind,restart:restart))}
    /// Continue opens the next main lesson from its start and plays it; practice activities are not on that path. A
    /// lesson read from training continues as one, as automatic continuation does: the way back to training stays and
    /// the course bookmark is untouched.
    func continueLesson(){guard let next=learning.library.nextMainLesson(after:learning.lessonIndex) else{return};playLesson(next)}
    /// The reverse of Continue: opens the previous main lesson paused on its last transcript, where the learner left it.
    func previousLessonEnd(){
        guard let previous=learning.library.previousMainLesson(before:learning.lessonIndex) else{return}
        if learning.readingFromTraining{guard navigate(.trainingLesson(id:learning.library.lessons[previous].id)) else{return}}
        else{guard navigate(.lesson(previous,resume:false)) else{return}}
        learning.pause();learning.seek(step:learning.current.beats.count-1)
    }
    /// Opens one of this lesson's practice activities, the same way Continue opens a lesson.
    func openPractice(_ index:Int){guard learning.library.practice(for:learning.lessonIndex).contains(index) else{return};playLesson(index)}
    private func playLesson(_ index:Int){
        if learning.readingFromTraining{guard navigate(.trainingLesson(id:learning.library.lessons[index].id)) else{return};learning.seek(step:0)}
        else{guard navigate(.lesson(index,resume:false)) else{return}};learning.play()}
    /// Quitting stops a running lesson translation or recording; the clip in progress is already paid for and is lost.
    /// Returns false when the learner chose to keep the app open. Tests inject an answer; automation never blocks.
    var confirmQuitDuringLessonJob:(()->Bool)?
    func mayQuitDuringLessonJob()->Bool {
        guard lessonLanguages.busy else{return true}
        if let confirm=confirmQuitDuringLessonJob{return confirm()};if NativePolicy.silent{return true}
        let alert=NSAlert.destructive(String(localized:"Stop the lesson job and quit?",bundle:.checkmate),lessonLanguages.recording ? String(localized:"A lesson recording is running. Completed text and clips are kept; the item in progress, already charged, is lost. Record / Resume continues later.",bundle:.checkmate):String(localized:"A lesson translation is running. Completed text and clips are kept; the item in progress, already charged, is lost. Record / Resume continues later.",bundle:.checkmate),action:String(localized:"Quit Anyway",bundle:.checkmate),cancel:String(localized:"Keep Working",bundle:.checkmate))
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Saves progress and every review before quitting; returns false when the learner chose to stay. A "Don't Save"
    /// given to a draft for this quit is spent when the quit is cancelled.
    func mayQuitAfterSaving()->Bool {let quit=mayQuitAfterSavingProgress() && mayQuitAfterSavingReviews();if !quit{draftDiscardApproved=nil};return quit}
    /// Answers "quit without these unsaved reviews?" with their count. Tests inject an answer; automation never blocks.
    var confirmQuitWithUnsavedReviews:((Int)->Bool)?
    /// Pointer acceptance shows the real unsaved-reviews alert in automation, to click its buttons like a person.
    static var quitAlertFixture:Bool {NativePolicy.silent && ProcessInfo.processInfo.environment["CHECKMATE_QUIT_ALERT_FIXTURE"]=="1"}
    /// Flushes the open review and every review whose earlier save failed. Any still unsaved keeps the app open unless
    /// the learner chooses to quit without them; Cancel leaves the warning and its Export the original PGN advice.
    private func mayQuitAfterSavingReviews()->Bool {
        saveReview(immediate:true);let unsaved=pendingReviewSnapshots.count;guard unsaved>0 else{return true}
        if let confirm=confirmQuitWithUnsavedReviews{return confirm(unsaved)};if NativePolicy.silent && !Self.quitAlertFixture{return true}
        let alert=NSAlert.destructive(unsaved==1 ? String(localized:"A review could not be saved.",bundle:.checkmate):String(localized:"\(unsaved) reviews could not be saved.",bundle:.checkmate),Sentences.join(reviewSaveWarning ?? String(localized:"Its latest imagined lines are only in memory.",bundle:.checkmate),String(localized:"Cancel to keep working, or quit without them.",bundle:.checkmate)),action:String(localized:"Quit Anyway",bundle:.checkmate))
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Saves before quitting. A failure offers Export Progress… (the in-memory state) instead of losing the last
    /// moves silently; returns false when the learner chose to stay.
    private func mayQuitAfterSavingProgress()->Bool {
        saveTask?.cancel()
        do{try store.save(session.state);return true}catch{
            if NativePolicy.silent{return true}
            let alert=NSAlert.destructive(String(localized:"Your latest progress could not be saved.",bundle:.checkmate),Sentences.join(userFacingMessage(error,fallback:String(localized:"The data folder may be full or read-only.",bundle:.checkmate)),String(localized:"Export it to keep it, or quit without it.",bundle:.checkmate)),action:String(localized:"Quit Anyway",bundle:.checkmate),alternative:String(localized:"Export Progress…",bundle:.checkmate))
            switch alert.runModal(){
            case .alertThirdButtonReturn:
                let panel=NSSavePanel();panel.nameFieldStringValue="checkmate-state.json";guard panel.runModal() == .OK,let url=panel.url else{return false}
                do{try store.exportState(session.state,to:url);return true}catch{storageError=userFacingMessage(error,fallback:String(localized:"The export could not be written. Choose another location.",bundle:.checkmate));return false}
            case .alertFirstButtonReturn:return true
            default:return false
            }
        }
    }
    enum DraftDisposal {case save,discard,cancel}
    /// Answers "save this draft review?" for a draft holding the learner's imagined lines. Tests inject an answer;
    /// otherwise the learner is asked (automation, which can never answer a modal, discards as before).
    var askAboutDraft:((Int)->DraftDisposal)?
    /// The draft, as it stood, that the learner chose not to save, so one exit (a saved review that loads first) asks
    /// once. A changed draft, or an exit that fails or is cancelled, asks again.
    private var draftDiscardApproved:(id:UUID,branches:[ReviewBranch])?
    /// Run before anything closes a draft review. Returns false when the learner chose to stay; a failed save also
    /// stays, so nothing is lost.
    func resolveDraftBeforeLeaving()->Bool {
        guard review.active,reviewDraft,let id=review.document?.id else{return true}
        let branches=review.branchesForSaving,ideas=branches.count,generation=reviewOpenGeneration;guard ideas>0 else{return true}
        if let approved=draftDiscardApproved,approved.id==id,approved.branches==branches{return true}
        let answer=askAboutDraft?(ideas) ?? askLearnerAboutDraft(ideas)
        // The question's modal run loop lets an agent change the draft, or navigate, meanwhile: an answer given about
        // another review, other imagined lines or a navigation since overtaken is never applied (no save, no discard
        // approval); the draft as it now stands is asked about again. Staying (Cancel) is always safe to apply.
        guard answer == .cancel || review.active && reviewDraft && review.document?.id==id && review.branchesForSaving==branches && reviewOpenGeneration==generation else{return resolveDraftBeforeLeaving()}
        switch answer {
        case .discard:draftDiscardApproved=(id,branches);return true
        case .cancel:return false
        case .save:return saveDraft()
        }
    }
    private func askLearnerAboutDraft(_ ideas:Int)->DraftDisposal {
        if NativePolicy.silent{return .discard}
        let alert=NSAlert.saveChanges(String(localized:"Save this review before leaving?",bundle:.checkmate),String(localized:"It holds \(ideas) imagined lines of yours that will be lost if you don’t save.",bundle:.checkmate))
        switch alert.runModal(){case .alertFirstButtonReturn:return .save;case .alertThirdButtonReturn:return .discard;default:return .cancel}
    }
    /// Saves the open draft; on failure it stays a draft (Save stays available) and is not retried in the background.
    @discardableResult private func saveDraft()->Bool {
        guard let id=review.document?.id else{return true};session.markReviewDraft(false)
        if saveReview(immediate:true){return true}
        session.markReviewDraft(true);pendingReviewSnapshots[id]=nil;return false
    }
    /// Imports progress and ends in practice on the imported game, from any activity (SH-9).
    func installImport(_ state:ApplicationState)throws -> URL {
        // The imported game replaces the one under a review: a review still open here (opened while the panel was up) is refused.
        guard !review.active else{throw CheckmateError.invalid(String(localized:"Leave the open review, then import the progress file again.",bundle:.checkmate))}
        var backup:URL?;_ = try transition(.importProgress(state,backup:{backup=$0}))
        guard let backup else{throw CheckmateError.cancelled};return backup
    }
    func importState(){
        // Importing replaces the game under any open review: leave the review first (asking about a draft).
        if review.active || reviewWorkspace{guard returnToGame() else{return}}
        // A review still being read could open while the panel is up: stop it now, and leave any review opened meanwhile before installing.
        reviewOpenGeneration+=1;cancelReviewImport()
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        panel.begin {response in
            guard response == .OK,let url=panel.url else{return}
            do {
                // Read no more than an archive may hold, so an oversized file is refused without loading it whole.
                let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
                let archive=try handle.read(upToCount:StateStore.maximumBytes+1) ?? Data()
                guard archive.count<=StateStore.maximumBytes else{throw CheckmateError.invalid(String(localized:"Invalid progress archive.",bundle:.checkmate))}
                var state=self.session.state
                let report=try LegacyImporter.apply(archive,to:&state,course:self.learning.library)
                let alert=NSAlert()
                if report.duplicate {alert.messageText=String(localized:"Already imported",bundle:.checkmate);alert.informativeText=report.summary;alert.runModal();return}
                alert.messageText=String(localized:"Import game and progress?",bundle:.checkmate)
                alert.informativeText=Sentences.join(report.summary,String(localized:"A separate copy of your current state will be kept in Backups.",bundle:.checkmate))
                let text=NSTextView(frame:NSRect(x:0,y:0,width:480,height:180));text.string=report.details;text.isEditable=false;text.isSelectable=true;text.font=styledFont(.body);text.textContainerInset=NSSize(width:8,height:8);text.setAccessibilityLabel(String(localized:"Import recovery report",bundle:.checkmate))
                let scroll=NSScrollView(frame:text.frame);scroll.hasVerticalScroller=true;scroll.borderType = .noBorder;scroll.documentView=text;alert.accessoryView=scroll
                alert.addButton(withTitle:String(localized:"Import",bundle:.checkmate));alert.addButton(withTitle:String(localized:"Cancel",bundle:.checkmate))
                guard alert.runModal() == .alertFirstButtonReturn else{return}
                if self.review.active || self.reviewWorkspace{guard self.returnToGame() else{return}}
                state=self.session.state
                let finalReport=try LegacyImporter.apply(archive,to:&state,course:self.learning.library)
                if finalReport.duplicate{return}
                let backup=try self.installImport(state)
                let result=NSAlert();result.messageText=String(localized:"Progress imported",bundle:.checkmate);result.informativeText=finalReport.summary;result.addButton(withTitle:String(localized:"Done",bundle:.checkmate,comment:"Verb: finish and dismiss"));result.addButton(withTitle:String(localized:"Show Backup",bundle:.checkmate))
                if result.runModal() == .alertSecondButtonReturn {NSWorkspace.shared.activateFileViewerSelecting([backup])}
            }catch {self.storageError=userFacingMessage(error,fallback:String(localized:"The progress file could not be imported. Your current progress is unchanged.",bundle:.checkmate))}
        }
    }
    /// Leaves a review (or the workspace) for the place it was opened over, resuming that place.
    @discardableResult func returnToGame()->Bool{navigate(.returnToGame)}
    func showReviewWorkspace(){navigate(.reviewWorkspace)}
    func saveCurrentReview(){
        guard review.active else{return};if reviewDraft{saveDraft()}else{saveReview(immediate:true)}
    }
    /// A review durably flushed on close is not re-saved by later debounces; failed records stay pending for retry.
    /// After a flushed review closes: closing re-queues the state just written, so drop exactly those snapshots (a failed
    /// or changed one stays pending) along with the debounced task that would have rewritten them.
    private func forgetFlushedReview(_ saved:Bool){guard saved,!review.active else{return};reviewSaveTask?.cancel();reviewSaveTask=nil
        pendingReviewSnapshots=pendingReviewSnapshots.filter{writtenReviewSnapshots[$0.key] != $0.value};writtenReviewSnapshots=[:]}
    /// Saves the open review and retries every earlier review whose save failed. Returns whether the open review (or,
    /// with none open, every pending review) is durably saved; the debounced path returns true once scheduled.
    @discardableResult func saveReview(immediate:Bool=false)->Bool{
        guard !restoringReview else{return false}
        if let deleting=deletingReviewID,review.document?.id==deleting{return false}
        if let document=review.document,!reviewDraft{pendingReviewSnapshots[document.id]=ReviewSnapshot(document:document,cursor:review.nodeID,branches:review.branchesForSaving)}
        guard !pendingReviewSnapshots.isEmpty else{return true}
        reviewSaveTask?.cancel();reviewSaveGeneration+=1;let generation=reviewSaveGeneration
        if immediate {
            var saved=true
            for (id,snapshot) in pendingReviewSnapshots {
                let result=Result{try reviewSaves.flush(snapshot.document,cursor:snapshot.cursor,branches:snapshot.branches,learnerSide:reviewSides[id])}
                finishReviewSave(id,snapshot:snapshot,result:result)
                if pendingReviewSnapshots[id] != nil,!review.active || review.document?.id==id{saved=false}
            }
            return saved
        }
        guard !shuttingDown else{return false}
        let snapshots=pendingReviewSnapshots
        reviewSaveTask=Task{[weak self] in try? await Task.sleep(for:.milliseconds(250));guard let self,!Task.isCancelled,!self.shuttingDown else{return}
            for (id,snapshot) in snapshots {
                self.reviewSaves.save(snapshot.document,cursor:snapshot.cursor,branches:snapshot.branches,learnerSide:self.reviewSides[id]){[weak self] result in Task{@MainActor in
                    guard let self=self,!self.shuttingDown,self.reviewSaveGeneration==generation else{return}
                    self.finishReviewSave(id,snapshot:snapshot,result:result)
                }}
            }
        }
        return true
    }
    private func finishReviewSave(_ id:UUID,snapshot:ReviewSnapshot,result:Result<[ReviewIndexEntry],Error>){
        switch result {
        case .success(let entries):reviews=entries;reviewLibraryGeneration+=1;writtenReviewSnapshots[id]=snapshot;if pendingReviewSnapshots[id]==snapshot{pendingReviewSnapshots[id]=nil}
        case .failure(CheckmateError.cancelled):pendingReviewSnapshots[id]=nil  // the record was deleted
        case .failure(let error):let warning=Self.reviewSaveFailure(error);reviewSaveWarning=warning;storageError=warning
        }
        reconcileReviewSaveWarning()
    }
    /// The save warning stays while any review is unsaved, and goes once none is.
    private func reconcileReviewSaveWarning(){if pendingReviewSnapshots.isEmpty,let warning=reviewSaveWarning{if storageError==warning{storageError=nil};reviewSaveWarning=nil}}
    /// Returns whether the review is open with its state restored; false when the learner kept a draft, the request was
    /// withdrawn while the draft question was up (`stillWanted`), or the restore failed.
    /// The learner's side in each review of a game they played (B-6), so it opens from their side; it is saved with the
    /// review and read back when a saved review opens. An imported record has none and opens from White's.
    private var reviewSides:[UUID:String]=[:]
    func reviewLearnerSide(_ document:GameDocument)->String? {reviewSides[document.id]}
    @discardableResult func openReview(_ document:GameDocument,saved:SavedReview?=nil,draft:Bool=false,stillWanted:()->Bool={true})->Bool{
        navigate(.review(document,saved:saved,draft:draft),stillWanted:stillWanted)
    }
    // MARK: Activity transitions (B8.2)
    /// A request to go somewhere else. Each case carries what its entry needs, so the commands that all end in practice
    /// (Practice a game, Return to game, an import, a practice fork) keep their own meaning.
    typealias Navigation=WorkspaceNavigation
    /// The one transition function: every navigation in the app runs these steps in this order.
    /// 1. The learner's say: leaving a draft with ideas asks first; a request withdrawn meanwhile (`stillWanted`) or a
    ///    Practise-here sheet whose position changed stops here, before anything changes.
    /// 2. Staging: every entry step that can fail runs before anything is left, so a failed entry leaves the current
    ///    activity exactly as it was (a failed restore, import or fork; Codex refute 4).
    /// 3. Exit, in a fixed order: the navigation token, pending review reads and the Practise-here request; the open
    ///    review's analysis, save and content; learning playback; voice; sound; practice work.
    /// 4. Entry, which changes the session's activity once (`GameSession.enter`).
    /// Returns false when the learner kept the current activity or the entry failed (its message is shown); an import
    /// that cannot be staged throws.
    @discardableResult func transition(_ next:Navigation,stillWanted:()->Bool={true})throws -> Bool {
        let place=session.activity.place,reviewing=session.activity.review != nil,token=reviewOpenGeneration
        let sameReview:Bool={if case .review(let document,_,_)=next{return review.document?.id==document.id};return false}()
        // 1. The learner's say. During a network game lessons, puzzles and training stay closed (LAN-play plan D8).
        if next.needsEngineHelp,!fairness.engineHelpAllowed{storageError=FairnessPolicy.destinationUnavailable;return false}
        if case .practiceFork=next,!practiceForkStillCurrent(){return false}
        guard sameReview || resolveDraftBeforeLeaving() else{return false}
        // A "Don't save" answered this request only: withdrawn, or overtaken by another navigation made while the question
        // was up (an agent's call runs during the modal), the draft stays and the next exit asks again.
        guard stillWanted(),reviewOpenGeneration==token else{draftDiscardApproved=nil;return false}
        // The draft question is modal and main-actor work (an agent's review call) runs during it: check the position again.
        if case .practiceFork=next,!practiceForkStillCurrent(){draftDiscardApproved=nil;return false}
        // A network game may also have begun while the question was up.
        if next.needsEngineHelp,!fairness.engineHelpAllowed{draftDiscardApproved=nil;storageError=FairnessPolicy.destinationUnavailable;return false}
        // 2. Staging.
        let coordinator=WorkspaceTransitionCoordinator(session:session,learning:learning,review:review);coordinator.training=training
        let staged:PreparedWorkspaceTransition
        do {
            // The review shown again is reloaded from its live state: a draft has no pending snapshot, and a saved one's may be older.
            let pending:ReviewSnapshot?={guard case .review(let document,_,_)=next else{return nil};if sameReview,let live=review.document{return ReviewSnapshot(document:live,cursor:review.nodeID,branches:review.branchesForSaving)};return pendingReviewSnapshots[document.id]}()
            staged=try coordinator.prepare(next,pendingReview:pending.map{(document:$0.document,cursor:$0.cursor,branches:$0.branches)})
        } catch WorkspaceEntryError.invalidRestore {
            draftDiscardApproved=nil;let waiting=reviewing ? false:session.requireExplicitResume()
            storageError=waiting ? Self.failedRestorePausedMessage:Self.failedRestoreMessage;return false
        } catch {
            // Every failed transition spends a "Don't save" given for it, thrown or not, so the next exit asks again.
            draftDiscardApproved=nil
            guard let fallback=Self.stagingFailure(next) else{throw error}
            if case .practiceFork=next{practiceForkRequested=false}
            storageError=userFacingMessage(error,fallback:fallback);return false
        }
        // The backup that an import or a fork keeps is the last staged step: it is written only for an entry that will happen.
        switch next {
        // The imported state is written here too: a write that fails leaves playback, connections and the activity alone.
        case .importProgress(_,let backup):if let state=staged.importedState{do{backup(try store.preserveBeforeImport(session.state));try store.save(state)}catch{draftDiscardApproved=nil;throw error}}
        case .practiceFork:do{_ = try store.preserveBeforeImport(session.state)}catch{practiceForkRequested=false;draftDiscardApproved=nil;storageError=userFacingMessage(error,fallback:String(localized:"Practice could not start from this position. The review is unchanged.",bundle:.checkmate));return false}
        default:break
        }
        // A staged training exercise is entered only over the record it was staged from: checked before any exit effect.
        guard coordinator.stillCurrent(staged) else{draftDiscardApproved=nil;storageError=WorkspaceTransitionCoordinator.staleTrainingMessage;return false}
        // 3. Exit.
        leave(for:next,reviewing:reviewing,sameReview:sameReview)
        // 4. Application entry; the host owns save notifications and native lifecycle effects.
        if case .review=next{restoringReview=true}
        do {
            try coordinator.enter(prepared:staged,from:place,wasReviewing:reviewing,beforeReviewRestore:{self.draftDiscardApproved=nil},afterReviewRestore:{self.restoringReview=false;self.saveReview();self.onReview?()})
            if case .importProgress=next{onImport?()}
            // The analysis cleared on the way in (PL-1) comes back from storage, with no search.
            // With "Analyze When Opened" (R-4), what is not stored is then analyzed; never during a network game.
            if case .review=next,let document=review.document{reviewAnalyzer.restore(document,analyze:session.state.settings.reviewAutoAnalyze)}
        } catch {
            switch next {
            case .practiceFork:storageError=userFacingMessage(error,fallback:String(localized:"Practice could not start from this position. The review was closed; your game is unchanged.",bundle:.checkmate));return false
            default:draftDiscardApproved=nil;throw error
            }
        }
        return true
    }
    /// `transition` for the learner's own commands: a failure it throws is said in the storage warning, never dropped.
    @discardableResult func navigate(_ next:Navigation,stillWanted:()->Bool={true})->Bool {
        do{return try transition(next,stillWanted:stillWanted)}catch{storageError=GameWindow.failureMessage(error);return false}
    }
    /// The message for a navigation whose staging failed, shown with nothing changed; nil when the failure is thrown.
    private static func stagingFailure(_ next:Navigation)->String? {
        switch next {
        case .practiceFork:return String(localized:"Practice could not start from this position. The review is unchanged.",bundle:.checkmate)
        case .trainingLibrary,.trainingExercise,.trainingScenario,.trainingResume,.trainingRetry,.trainingLegacy:return String(localized:"This exercise could not be opened. Nothing was changed.",bundle:.checkmate)
        case .trainingLesson:return String(localized:"This lesson could not be opened. Nothing was changed.",bundle:.checkmate)
        case .practice,.returnToGame,.lesson,.puzzles,.reviewWorkspace,.review,.importProgress,.network:return nil
        }
    }
    /// Step 3 of `transition`: everything the current activity holds stops, in a fixed order.
    private func leave(for next:Navigation,reviewing:Bool,sameReview:Bool){
        reviewOpenGeneration+=1;cancelReviewImport();practiceForkRequested=false;practiceForkIdentity=nil
        // Every way out of a review, and every review shown, starts with no whole-game analysis holding the engine (PL-1).
        let entersReview:Bool={if case .review=next{return true};return false}()
        if reviewing || entersReview{reviewAnalyzer.reset()}
        // The open review is saved and closed unless it is the one being shown again.
        if review.active && !sameReview{let saved=saveReview(immediate:true);review.unload();forgetFlushedReview(saved)}
        // A move sound still waiting for its animation belongs to the activity being left, as does a voice preview.
        cancelMoveSounds();voicePreview.cancel()
        switch next {
        case .returnToGame:break
        // A coach opened for the network game (assistance plan A10) coaches it only on its own page; the network page
        // itself keeps it, and ends a practice session.
        case .practice:if !reviewing{learning.pause()};if voice.networkSession || voice.miniReviewSession != nil || voice.trainingSession{voice.disconnect()};audio.stop()
        // A lesson's player is paused too: its timer would otherwise narrate and auto-advance into a lesson (D8).
        case .network:learning.pause();if !voice.networkSession{rememberVoice();voice.disconnect()};audio.stop()
        case .lesson,.puzzles:rememberVoice();voice.disconnect();audio.stop()
        case .reviewWorkspace,.review:learning.pause();rememberVoice();voice.disconnect();audio.stopAll()
        case .importProgress:saveTask?.cancel();voice.disconnect();usage.flushForShutdown();companion.disable();learning.pause();audio.stopAll()
        case .practiceFork:session.cancelWork()
        case .trainingLibrary,.trainingExercise,.trainingScenario,.trainingResume,.trainingRetry,.trainingLegacy,.trainingLesson:learning.pause();rememberVoice();voice.disconnect();audio.stop()
        }
    }
    private func cancelMoveSounds(){soundTasks.values.forEach{$0.cancel()};soundTasks=[:]}
    func openSavedReview(_ id:UUID){
        reviewOpenGeneration+=1;cancelReviewImport();let generation=reviewOpenGeneration
        guard !shuttingDown,review.document?.id != id,resolveDraftBeforeLeaving() else{return}
        // The draft question is modal: another navigation made meanwhile wins, and this load never starts.
        guard reviewOpenGeneration==generation else{draftDiscardApproved=nil;return}
        let store=reviewStore,delay=NativePolicy.silent ? min(2000,max(0,automationReviewLoadDelayMs)):0
        importingReview=true
        reviewImportTask=Task{do{
            if delay>0{try await Task.sleep(for:.milliseconds(delay))}
            let saved=try await Task.detached{try store.load(id)}.value
            guard !Task.isCancelled,!shuttingDown,reviewOpenGeneration==generation else{return};importingReview=false
            reviewSides[saved.document.id]=saved.learnerSide;openReview(saved.document,saved:saved)
        }catch{guard !Task.isCancelled,!shuttingDown,reviewOpenGeneration==generation else{return};importingReview=false;draftDiscardApproved=nil;storageError=String(localized:"The saved review could not be opened; its file is preserved.",bundle:.checkmate)}}
    }
    func requestDeleteReview(_ id:UUID){
        guard deletingReviewID==nil,let record=reviews.first(where:{$0.id==id}) else{return}
        let alert=NSAlert.destructive(String(localized:"Delete “\(record.title)”?",bundle:.checkmate),String(localized:"This removes the saved review and its imagined lines; Edit ▸ Undo puts them back. Your current game and the original imported file are kept.",bundle:.checkmate),action:String(localized:"Delete",bundle:.checkmate),identifier:"review-delete")
        if let window=NSApp.mainWindow{alert.beginSheetModal(for:window){[weak self] response in if response == .alertFirstButtonReturn{self?.deleteReview(id)}}}
        else if alert.runModal() == .alertFirstButtonReturn{deleteReview(id)}
    }
    /// Restart from the drawer, the bar or the menu. Past the first exchange it asks first, with Cancel the default; a
    /// confirmation answered after the attempt was replaced (left, restarted, reloaded) does nothing.
    func requestRestartAttempt(){
        let attempt:LessonAttemptController=learning.attempt
        guard attempt.restartNeedsConfirmation,let shown=attempt.record?.id else{attempt.restart();return}
        let alert=NSAlert.destructive(String(localized:"Start this exercise again?",bundle:.checkmate),String(localized:"The moves of this attempt are cleared. Anything you have already achieved in it stays achieved.",bundle:.checkmate),action:String(localized:"Start Again",bundle:.checkmate))
        let answered:(NSApplication.ModalResponse)->Void={[weak self] response in guard response == .alertFirstButtonReturn,let self,self.learning.attempt.record?.id==shown else{return};self.learning.attempt.restart()}
        if let window=NSApp.mainWindow{alert.beginSheetModal(for:window,completionHandler:answered)}else{answered(alert.runModal())}
    }
    /// What Edit ▸ Undo does now (R-12): the one place its title, enabling and action are decided.
    enum UndoAction:Equatable {
        /// Put back the saved review deleted last; nothing Undo owns has happened since.
        case restoreReview(UUID)
        /// The game's own: take back, undo turn.
        case game
        /// In a review nothing else is undone.
        case nothing
    }
    var undoAction:UndoAction {
        if let deletion=undoableDeletion{if deletion.context==undoContext{return .restoreReview(deletion.id)};undoableDeletion=nil}
        return review.active || reviewWorkspace ? .nothing:.game
    }
    /// What Undo would act on besides a deletion, as far as the learner made it: only what they do counts, so a reply
    /// landing after the deletion (Practice's computer, a lesson's, a mini-game's or the training defender) keeps it.
    struct UndoContext:Equatable {
        let activity:Activity,game:Int,learnerMoves:Int,review:UUID?,ideas:[ReviewBranch],mini:Mini?,attempt:Attempt?,training:Training?
        /// A mini-game as the learner's last move left it: against the computer the learner is White, so once its reply
        /// has landed that is the position before the reply.
        struct Mini:Equatable {let kind:MiniGameKind,computer:Bool,seed:String?,afterLearner:MiniGameSnapshot}
        /// A lesson exercise's attempt, counting only the learner's (White's) moves; hints and playing on are theirs too.
        struct Attempt:Equatable {let id:String,definition:String,learnerMoves:Int,hints:Int,playOn:Bool}
        /// A training attempt's actions without the defender's or the objective's replies.
        struct Training:Equatable {let id:String,learnerActions:[TrainingAction],help:Bool}
    }
    private var undoContext:UndoContext {
        let mini=learning.miniGame.map{game in UndoContext.Mini(kind:game.kind,computer:game.computer,seed:game.opponentSeed,afterLearner:game.computer && game.snapshot.turn==learning.miniLearnerSide ? game.history.last ?? game.snapshot:game.snapshot)}
        let attempt=learning.attempt.record.map{UndoContext.Attempt(id:$0.id,definition:$0.definition,learnerMoves:learning.attempt.rules.records.filter{$0.color=="w"}.count,hints:$0.hints,playOn:$0.playOn)}
        let training=(training?.exercise?.snapshot).map{UndoContext.Training(id:$0.id,learnerActions:$0.actions.filter{if case .reply=$0{return false};return true},help:$0.recordedHelp)}
        return UndoContext(activity:session.activity,game:session.gameGeneration,learnerMoves:session.rules.records.filter{$0.color==session.humanSide}.count,review:review.document?.id,ideas:review.branchesForSaving.sorted{$0.id.uuidString<$1.id.uuidString},mini:mini,attempt:attempt,training:training)
    }
    /// The deletion Undo can still put back, with what Undo would otherwise have acted on then; any change to that
    /// drops it for good (`undoAction`, and the sink in `observeSession`).
    private var undoableDeletion:(id:UUID,context:UndoContext)?
    /// Undo's restore: the deleted review comes back, once.
    func undoDeletion(){guard case .restoreReview(let id)=undoAction else{return};undoableDeletion=nil;restoreDeletedReview(id)}
    /// Deletes a saved review into the library's Trash; until the learner does anything else Undo owns, Edit ▸ Undo
    /// puts it back.
    func deleteReview(_ id:UUID){
        guard deletingReviewID==nil else{return}
        // A saved review still loading is abandoned with its "Loading review…" overlay, never left showing it.
        deletingReviewID=id;reviewLibraryGeneration+=1;reviewOpenGeneration+=1;cancelReviewImport()
        reviewSaveGeneration+=1;reviewSaveTask?.cancel()
        let writer=reviewSaves
        Task {
            do {
                let entries=try await Task.detached{try writer.delete(id)}.value
                pendingReviewSnapshots[id]=nil;reconcileReviewSaveWarning()
                if review.document?.id==id{navigate(.returnToGame)}
                reviews=entries;deletingReviewID=nil
                if review.active{saveReview()}
                undoableDeletion=(id,undoContext)
            } catch {
                deletingReviewID=nil
                storageError=String(localized:"The review could not be deleted. Its saved record is preserved; try again.",bundle:.checkmate)
                if review.active{saveReview()}
            }
        }
    }
    /// "Rename…" on a saved review (R-11): its name is stored in its record and index, and its saved time is kept.
    func requestRenameReview(_ id:UUID){
        guard let entry=reviews.first(where:{$0.id==id}) else{return}
        NSAlert.askName(String(localized:"Rename Saved Review",bundle:.checkmate),current:entry.title,identifier:"review-rename-field"){[weak self] name in self?.renameReview(id,to:name)}
    }
    /// An empty name gives the review back its game's title.
    func renameReview(_ id:UUID,to name:String){
        let writer=reviewSaves;reviewLibraryGeneration+=1
        Task {
            do{reviews=try await Task.detached{try writer.rename(id,to:ReviewIndexEntry.cleanName(name))}.value}
            catch{storageError=userFacingMessage(error,fallback:String(localized:"The review could not be renamed. Try again.",bundle:.checkmate))}
        }
    }
    /// Undo of `deleteReview`: the record comes back from the Trash into the library list, with the engine analysis
    /// kept while it was there.
    func restoreDeletedReview(_ id:UUID){
        let writer=reviewSaves;reviewLibraryGeneration+=1
        Task {
            do{reviews=try await Task.detached{try writer.restore(id)}.value}
            catch{storageError=userFacingMessage(error,fallback:String(localized:"The deleted review could not be put back.",bundle:.checkmate))}
        }
    }
    /// The training game the board shows, if any (not the training library): File ▸ Review Current Game reviews this
    /// game, not the practice game beside it (mini-games plan D6).
    var shownTrainingExercise:TrainingController.Exercise? {
        guard case .training=session.activity.place else{return nil}
        return training?.exercise
    }
    /// Whether File ▸ Review Current Game has a game to open: the training game the board shows, and only if it is
    /// finished, else the practice game.
    var canReviewCurrent:Bool {
        if let exercise=shownTrainingExercise{return training?.canReview(exercise)==true}
        return !session.rules.history.isEmpty
    }
    /// The game's text is read here; parsing it (seconds for a long game) runs detached, under the import overlay and its Cancel.
    func reviewCurrent(previous:Bool=false){
        // A training game on screen is what "current" means there; an unfinished one is not reviewed and never falls
        // back to the unrelated practice game.
        if !previous,let exercise=shownTrainingExercise {
            guard training?.canReview(exercise)==true else{return}
            reviewTraining();return
        }
        reviewOpenGeneration+=1;cancelReviewImport();let provenance:ReviewProvenance=previous ? .previousGame:.currentGame,fallback=String(localized:"This game could not be opened for review. Your practice is unchanged.",bundle:.checkmate)
        let data:Data;do{data=previous ? try ReviewRecordSource.data(previousGame:session.state.practice.previousGame,result:session.state.practice.previousEnding?.result):try ReviewRecordSource.data(session.rules,result:session.state.practice.ending?.result)}catch{storageError=userFacingMessage(error,fallback:fallback);return}
        let side=previous ? session.state.practice.previousSide:session.humanSide
        parseForReview(data,provenance:provenance,fallback:fallback){documents,_ in self.reviewSides[documents[0].id]=side;self.openReview(documents[0],draft:true)}
    }
    /// The finished training game shown, as a draft review (mini-games plan D6): read from the attempt's own start and
    /// actions, never the practice game. The review covers the training entry, so Return to game leads back to it.
    func reviewTraining(){
        reviewOpenGeneration+=1;cancelReviewImport();let fallback=String(localized:"This game could not be opened for review. Your training is unchanged.",bundle:.checkmate)
        guard let training else{return}
        let data:Data;do{data=try training.reviewRecord()}catch{storageError=userFacingMessage(error,fallback:fallback);return}
        let side=shownTrainingExercise?.scenario.learner
        parseForReview(data,provenance:.trainingGame,fallback:fallback){documents,_ in self.reviewSides[documents[0].id]=side;self.openReview(documents[0],draft:true)}
    }
    /// The review workspace's game library (bundled games and imported collections), in the data directory's own
    /// `Library/` folder, apart from `Reviews/`.
    lazy var library:ReviewLibraryController={let controller=ReviewLibraryController(directory:store.directory.appendingPathComponent("Library"));controller.model=self;controller.follow($reviews);return controller}()
    /// A library or collection game opens as a draft review through the same cancellable parse as any imported record.
    /// The record must read as exactly one game with nothing skipped, and pass `verify` (a bundled game must replay to
    /// its manifest entry), or nothing opens.
    func openLibraryRecord(_ data:Data,provenance:ReviewProvenance,fallback:String,verify:@escaping (GameDocument)throws->Void={_ in}){
        parseForReview(data,provenance:provenance,delay:NativePolicy.silent ? min(2000,max(0,automationReviewImportDelayMs)):0,fallback:fallback){documents,skipped in
            guard documents.count==1,skipped.isEmpty else{throw CheckmateError.invalid(String(localized:"This library record does not hold exactly one readable game.",bundle:.checkmate))}
            try verify(documents[0]);self.openReview(documents[0],draft:true)
        }
    }
    /// `learnerSide` is the learner's own side when the record is a game they played (a network game).
    func importReviewData(_ data:Data,learnerSide:String?=nil){
        // Many games (R-9) join the library as a collection, searchable and sortable there, with the first selected; the
        // collection reads them once, under its own limit rather than the review's.
        let collection={self.showReviewWorkspace();self.library.load();self.library.importCollection(data)}
        parseForReview(data,delay:NativePolicy.silent ? min(2000,max(0,automationReviewImportDelayMs)):0,fallback:String(localized:"This record could not be imported. Your current game and reviews are unchanged.",bundle:.checkmate),several:collection){documents,skipped in
            // Unreadable games beside the readable ones are skipped, and the learner is told which.
            if let first=skipped.first{self.storageError=String(localized:"\(skipped.count) games in this file could not be read and were skipped.",bundle:.checkmate)+" "+(first.errorDescription ?? "")}
            if documents.count==1{self.reviewSides[documents[0].id]=learnerSide;self.openReview(documents[0],draft:true);return}
            // The review parse may still find several games where the lexer's recovery found one.
            collection()
        }
    }
    /// One cancellable parse for every review made from text (the current game, a file, a paste or a drop): it replaces
    /// any older open or import, runs detached under the import overlay and its Cancel, and presents only while no
    /// other activity was chosen. A record with no readable game fails with `fallback` or its own reason. With `several`,
    /// a record of several readable games is not parsed for review but handed to `several` instead.
    private func parseForReview(_ data:Data,provenance:ReviewProvenance = .imported,delay:Int=0,fallback:String,several:(()->Void)?=nil,present:@escaping (_ documents:[GameDocument],_ skipped:[ReviewImportError])throws->Void){
        reviewOpenGeneration+=1;cancelReviewImport();let generation=reviewOpenGeneration,token=ReviewImportCancellation();reviewImportCancellation=token;importingReview=true
        let routes=several != nil
        reviewImportTask=Task{do{
            if delay>0{try await Task.sleep(for:.milliseconds(delay))}
            let report=try await withTaskCancellationHandler(operation:{try await Task.detached{try routes && PGNImporter.holdsSeveralRecords(data,cancelled:{token.cancelled}) ? nil:PGNImporter.parseReport(data,provenance:provenance,cancelled:{token.cancelled})}.value},onCancel:{token.cancel()})
            guard !Task.isCancelled,reviewOpenGeneration==generation else{return};importingReview=false
            guard let report else{several?();return}
            guard !report.documents.isEmpty else{throw CheckmateError.invalid(String(localized:"No games found in this record.",bundle:.checkmate))}
            try present(report.documents,report.skipped)
        }catch{guard !Task.isCancelled else{return};importingReview=false;storageError=userFacingMessage(error,fallback:fallback)}}
    }
    /// Every exit that asked about a draft finishes at once except a saved review's load, so a cancelled load also
    /// spends that answer.
    /// A review file the learner just chose starts reading: it replaces any older open or import still running, so an
    /// earlier file's parse cannot finish first and take over.
    func supersedeReviewOpen(){reviewOpenGeneration+=1;cancelReviewImport()}
    func cancelReviewImport(){draftDiscardApproved=nil;reviewImportCancellation?.cancel();reviewImportCancellation=nil;reviewImportTask?.cancel();reviewImportTask=nil;importingReview=false}
    /// Reads review files off the main thread, one at a time, with the drop's checks and bounded read.
    lazy var reviewFiles:ReviewFileReader={let reader=ReviewFileReader();reader.activity={[weak self] in self?.activityGeneration ?? -1};reader.supersede={[weak self] in self?.supersedeReviewOpen()};return reader}()
    /// `directory` is where the panel starts; the review scenario points it at its fixture before the panel opens.
    /// A file File ▸ Open… opened, for File ▸ Open Recent (R-15).
    var openedFile:(URL)->Void={_ in}
    func openPGN(startingIn directory:URL?=nil){let panel=NSOpenPanel();panel.allowedContentTypes=ReviewFileTypes.openable;panel.allowsMultipleSelection=false;if let directory{panel.directoryURL=directory};panel.begin{[weak self] response in guard let self,response == .OK,let url=panel.url else{return}
        self.reviewFiles.load(url,prepare:ReviewDrop.validated,deliver:{[weak self] in self?.openedFile(url);self?.importReviewData($0)},rejected:{[weak self] error in self?.storageError=(error as? ReviewDrop.Rejection)?.reason ?? String(localized:"The selected file could not be read. Your current game and reviews are unchanged.",bundle:.checkmate)})}}
    func pasteReview(){guard let text=NSPasteboard.general.string(forType:.string) else{storageError=String(localized:"Copy PGN or FEN text first.",bundle:.checkmate);return};importReviewData(Data(text.utf8))}
    /// The open review as one PGN record (R-13): its moves, the learner's imagined lines as variations, and, when the
    /// engine has analysed this review and engine help is allowed, each move's evaluation and grade. Replaying the lines
    /// takes a chess.js context each, so the returned work runs off the main actor (Export and Copy PGN both use it).
    func reviewPGN()->(@Sendable ()throws->Data)? {
        guard let d=review.document else{return nil};let branches=review.branchesForSaving
        let (evaluations,grades)=reviewAnalyzer.exportedAnalysis(d)
        return {try PGNExporter.withIdeas(d,branches:branches,evaluations:evaluations,grades:grades)}
    }
    /// The title an export is named after: the saved review's own name, else its game's title.
    func reviewExportTitle(_ d:GameDocument)->String {reviews.first{$0.id==d.id}?.name ?? d.title}
    /// A review exports unless it is shown over the network place, where no game leaves the app (as `ShownRecord`).
    var mayExportReview:Bool {review.active && session.mode != .network}
    func exportReview(){
        guard mayExportReview,let d=review.document,let build=reviewPGN() else{return};let branches=review.branchesForSaving,title=reviewExportTitle(d)
        let panel=NSSavePanel();panel.nameFieldStringValue=Self.exportName(title,document:d,ideas:false)
        let choice=NSPopUpButton(frame:NSRect(x:0,y:0,width:260,height:28));choice.addItems(withTitles:[String(localized:"Original record",bundle:.checkmate),String(localized:"Original and my imagined lines",bundle:.checkmate)]);choice.setAccessibilityLabel(String(localized:"Export contents",bundle:.checkmate))
        // A FEN-only original exports as FEN; adding ideas always produces PGN records.
        let naming=ExportNaming(panel:panel,document:d,title:title);choice.target=naming;choice.action=#selector(ExportNaming.choiceChanged(_:))
        if branches.contains(where:{!$0.moves.isEmpty}){panel.accessoryView=choice}
        panel.begin{response in withExtendedLifetime(naming){};guard response == .OK,let url=panel.url else{return};let ideas=choice.indexOfSelectedItem==1
            // Each idea replays its history in a new chess.js context: build and write the file off the main thread.
            Task{do{try await Task.detached{try (ideas ? build():d.original).write(to:url,options:.atomic)}.value}catch{self.storageError=String(localized:"The review could not be exported.",bundle:.checkmate)}}}
    }
    /// The sheet forks the position it was opened for (RV-11): any transition ends the request, and a review changed
    /// under the sheet (open, paste, an agent) is refused.
    private var practiceForkIdentity:String?
    func practiceFromReview(){practiceForkIdentity=review.identity+":\(review.branchPly)";practiceForkRequested=true}
    private func practiceForkStillCurrent()->Bool {
        guard practiceForkRequested,review.active,practiceForkIdentity==review.identity+":\(review.branchPly)" else{practiceForkRequested=false;practiceForkIdentity=nil;storageError=String(localized:"The review changed while you were choosing. Choose Practice Here again.",bundle:.checkmate);return false};return true}
    /// Forks exactly the displayed position: an imagined line replays from its own root (for "Compare best line", the
    /// parent), with history-aware automatic terminal rules.
    func confirmPracticeFork(side:String,preset:String){navigate(.practiceFork(side:side,preset:preset))}
    static func exportName(_ title:String,document:GameDocument,ideas:Bool)->String {PGNExporter.fileName(title,pgn:document.historyAvailable || ideas)}
    func showBackups(){NSWorkspace.shared.activateFileViewerSelecting([store.directory])}
    func exportState(){let panel=NSSavePanel();panel.nameFieldStringValue="checkmate-state.json";panel.begin {response in guard response == .OK,let url=panel.url else{return};do{try self.store.exportState(self.session.state,to:url)}catch{self.storageError=userFacingMessage(error,fallback:String(localized:"The export could not be written. Choose another location.",bundle:.checkmate))}}}
    func shutdown(){network.shutdown();lessonLanguages.shutdown();connectionStartup?.cancel();voicePreview.cancel();voiceResumeIntent=false;reviewTools.reset();reviewOpenGeneration+=1;cancelReviewImport();saveReview(immediate:true);shuttingDown=true;reviewSaveTask?.cancel();review.cancel();saveTask?.cancel();cancelMoveSounds();session.prepareShutdown();voice.disconnect();usage.flushForShutdown();companion.disable();learning.shutdown();audio.stopAll();session.cancelWork();try? store.save(session.state)}
}
/// Keeps the Save panel's suggested extension consistent with the chosen export contents.
@MainActor final class ExportNaming:NSObject {
    weak var panel:NSSavePanel?;let document:GameDocument,title:String
    init(panel:NSSavePanel,document:GameDocument,title:String){self.panel=panel;self.document=document;self.title=title}
    @objc func choiceChanged(_ sender:NSPopUpButton){
        guard let panel=panel else{return};let name=NativeModel.exportName(title,document:document,ideas:sender.indexOfSelectedItem==1)
        let stem=(panel.nameFieldStringValue as NSString).deletingPathExtension;panel.nameFieldStringValue=(stem.isEmpty ? "review":stem)+"."+(name as NSString).pathExtension
    }
}
