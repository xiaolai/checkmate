import AppKit
import UniformTypeIdentifiers
import Combine
import CheckmateCore
@MainActor final class NativeModel:ObservableObject {
    let session:GameSession,learning:LearningPlayer,audio:NativeAudio,store:StateStore
    let companion:CompanionBroker,voice:VoiceCoach
    let usage:UsageLedger,lessonLanguages:LessonLanguageController
    let review=ReviewController()
    let reviewStore:ReviewStore,reviewAnalyzer:ReviewAnalyzer
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
        return "The review could not be saved"+(reason.isEmpty ? "":": "+reason.trimmingCharacters(in:CharacterSet(charactersIn:".")))+". Export the original PGN before quitting."
    }
    private var reviewSaveTask:Task<Void,Never>?
    private static let progressSaveFailure="Your progress could not be saved. Export it before quitting."
    private var shuttingDown=false
    private var connectionStartup:ConnectionStartup?
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
    /// "Return to game"/"Resume game" action. A new game, restore, import, fork or lesson clears it with the position.
    var restoreResumePending:Bool {session.explicitResumeRequired}
    static let failedRestoreMessage="The saved review could not be restored; its file is preserved."
    static let failedRestorePausedMessage=failedRestoreMessage+" Your game is paused. Choose Return to game to continue."
    func resumeAfterFailedRestore(){storageError=nil;practice()}
    init() throws {
        if !NativePolicy.silent {Task.detached{CodexSubscriptionClient.cleanAbandonedPrivateHomes()}}
        store=StateStore(directory:StateStore.defaultDirectory());let state=try store.load();store.preserveFirstLaunchBackup()
        let engine=NativeEngine();reviewAnalyzer=ReviewAnalyzer(engine:engine,cacheDirectory:store.directory.appendingPathComponent("ReviewAnalysis"));reviewStore=ReviewStore(directory:store.directory.appendingPathComponent("Reviews"))
        reviewSaves=ReviewSaveCoordinator(store:reviewStore)
        session=try GameSession(engine:engine,state:state);learning=try LearningPlayer(session:session);audio=NativeAudio(scores:learning.library.sounds);learning.audio=audio
        companion=try CompanionBroker(session:session,directory:store.directory.appendingPathComponent("companion"));voice=try VoiceCoach(session:session)
        usage=UsageLedger(directory:store.directory.appendingPathComponent("Usage"))
        if NativePolicy.silent,ProcessInfo.processInfo.environment["CHECKMATE_LESSON_FIXTURE"]=="1" {
            lessonLanguages=try LessonLanguageController(library:learning.library,directory:store.directory,usage:usage,translator:LessonAutomationTranslator(),recorder:LessonAutomationRecorder())
            lessonLanguages.cleanupPause = .seconds(2)
        } else {
            lessonLanguages=try LessonLanguageController(library:learning.library,directory:store.directory,usage:usage)
        }
        lessonLanguages.language=state.settings.lessonLanguage;lessonLanguages.voice=state.settings.lessonVoice
        learning.packs=lessonLanguages.store;voice.usageLedger=usage;voice.connectionBlocked={[weak self] in self?.lessonLanguages.recording==true || self?.audio.isNarrationPlaying==true}
        voice.connectionBlockReason={[weak self] in self?.lessonLanguages.recording==true ? "Finish or cancel lesson recording before connecting the voice coach.":"Stop lesson or preview playback before connecting the voice coach."}
        lessonLanguages.voiceConflict={[weak self] in self?.voice.connected==true || self?.voice.connecting==true}
        // Settings effects are not navigation (LE-5): the Lesson picker only stops a preview of the old selection; a preview
        // or a removal stops lesson narration (one narration channel) but never a mini-game's pending computer reply.
        lessonLanguages.onSelectionChange={[weak self] in guard let self,!self.learning.playing else{return};self.audio.stop()};lessonLanguages.onPacksChanged={[weak self] in self?.learning.reloadLocalizedPacks()};lessonLanguages.beforeRemove={[weak self] in guard let self else{return};if self.lessonLanguages.allLessons || self.lessonLanguages.selectedLesson==self.learning.lessonIndex{self.learning.pauseNarration();self.audio.stop()}else if !self.learning.playing{self.audio.stop()}}
        lessonLanguages.playPreview={[weak self] url in guard let self else{return};self.learning.pauseNarration();self.audio.play(localURL:url,seconds:0,settings:self.session.state.settings);self.lessonLanguages.reportPreviewPlayback(failure:self.audio.narrationFailure)}
        session.reviewController=review;voice.attachReview(review)
        let reviewTools=ReviewTools(review:review,session:session,store:reviewStore,analyzer:reviewAnalyzer);reviewTools.onOpen={[weak self] document,saved in self?.openReview(document,saved:saved,stillWanted:{!Task.isCancelled}) ?? false};reviewTools.onPractice={[weak self] in self?.practiceFromReview()};companion.tools.reviewTools=reviewTools;self.reviewTools=reviewTools
        reviewTools.activityGeneration={[weak self] in self?.reviewOpenGeneration ?? -1}
        companion.tools.reviewOpenAllowed={[weak self] in guard let self else{return false};return self.reviewWorkspace || self.review.active}
        session.onPersist={[weak self] state in guard let self=self else{return};self.saveTask?.cancel();self.saveTask=Task{try? await Task.sleep(nanoseconds:250_000_000);guard !Task.isCancelled else{return};do{try self.store.save(state);if self.storageError==Self.progressSaveFailure{self.storageError=nil}}catch{NativeLog.storage.error("State save failed; export remains available");self.storageError=Self.progressSaveFailure}}}
        learning.onIllustration={[weak self] piece,capture in guard let self=self else{return};self.audio.illustration(piece:piece,capture:capture,settings:self.session.state.settings)}
        session.onMove={[weak self] move in guard let self=self else{return};let settings=self.session.state.settings;let delay=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || self.movePlacedDirectly?(move)==true ? 0:settings.pieceDuration;let id=UUID();self.soundTasks[id]=Task{defer{self.soundTasks.removeValue(forKey:id)};try? await Task.sleep(nanoseconds:UInt64(delay)*1_000_000);guard !Task.isCancelled else{return};self.audio.move(move,settings:settings)}}
        learning.onMiniMove=session.onMove
        learning.onMiniReset={[weak self] in self?.soundTasks.values.forEach{$0.cancel()};self?.soundTasks=[:]}
        session.onUndo={[weak self] in guard let self=self else{return};self.soundTasks.values.forEach{$0.cancel()};self.soundTasks=[:];self.audio.move(nil,settings:self.session.state.settings,undo:true)}
        let reviewStore=reviewStore;Task{do{let (entries,moved)=try await Task.detached{let entries=try reviewStore.list();return (entries,reviewStore.takeQuarantinedCount())}.value
            if moved>0{storageError="\(moved) saved review\(moved==1 ? "":"s") could not be read and \(moved==1 ? "was":"were") moved to the Quarantine folder inside Reviews. Nothing was deleted."}
            guard reviewLibraryGeneration==0 else{return};reviews=entries}catch{storageError="Saved reviews could not be loaded. Your current practice is unchanged."}}
        review.onEvent={[weak self] in self?.session.signalEvent();self?.saveReview()}
        // The workspace and draft flags read the session's activity; views observing this model follow it.
        session.$activity.removeDuplicates().dropFirst().sink{[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        // The banner observes this model; forward gate changes, and drop the paused sentence once the held game resumed or changed.
        session.$explicitResumeRequired.removeDuplicates().dropFirst().receive(on:RunLoop.main).sink{[weak self] held in guard let self=self else{return};self.objectWillChange.send();if !held,self.storageError==Self.failedRestorePausedMessage{self.storageError=Self.failedRestoreMessage}}.store(in:&observations)
        session.$state.map(\.settings).removeDuplicates().dropFirst().receive(on:RunLoop.main).sink {[weak self] _ in guard let self else{return};self.syncLessonSelection();self.learning.settingsChanged();self.voice.settingsChanged()}.store(in:&observations)
        // A running lesson job keeps the language and voice it started with; the selection follows settings once it ends.
        lessonLanguages.$busy.removeDuplicates().filter{!$0}.receive(on:RunLoop.main).sink{[weak self] _ in self?.syncLessonSelection()}.store(in:&observations)
    }
    /// The launch attempt waited while the app was hidden (Cmd-H during the check, or launched hidden); run it now.
    func resumeConnectionsIfDeferred(){connectionStartup?.resumeIfDeferred()}
    /// Voice may take the session only in practice itself: never in a lesson, puzzle, review or the review workspace (TX-3).
    var voiceMayConnect:Bool {session.activity == .at(.practice) && !session.suspended}
    /// Away: the app hidden or its window minimised (TX-5). Agents and Stockfish wait, voice disconnects; on return the
    /// connection resumes and a launch check that waited runs.
    private(set) var away=false
    func setAway(_ value:Bool){guard value != away else{return};away=value
        // The session itself holds play, with or without the MCP broker; voice disconnects only once play is held.
        if companion.enabled{companion.suspend(value)}else{session.setConnection(enabled:false,role:session.companionRole,suspended:value)}
        if value{voice.disconnect()}else{resumeConnectionsIfDeferred()}}
    private func syncLessonSelection(){guard !lessonLanguages.busy else{return};lessonLanguages.language=session.state.settings.lessonLanguage;lessonLanguages.voice=session.state.settings.lessonVoice}
    func startConnections(){
        guard connectionStartup==nil,!NativePolicy.silent else{return}
        let activity=activityGeneration,voiceGeneration=voice.connectionGeneration,brokerGeneration=companion.connectionGeneration
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
            startMCP:{[weak self] in
                guard let self,CompanionInstallation.installedCodex() != nil else{return}
                do{try companion.enable(role:session.state.settings.companionRole,standby:true)}
                catch{companion.disable()}
            },
            stillCurrent:{[weak self] in
                guard let self else{return false}
                return !shuttingDown && companion.connectionGeneration==brokerGeneration
            },
            visible:{[weak self] in guard let self else{return false};return !NSApp.isHidden && !session.suspended})
        connectionStartup?.start()
    }
    /// Sidebar Practice a game. A review opened over practice returns to it exactly as Return to game does (a Try a
    /// move or demonstration is kept, TX-8); from anywhere else the game is shown.
    func practice(){_ = try? transition(.practice)}
    func lesson(_ index:Int){_ = try? transition(.lesson(index))}
    func puzzles(){_ = try? transition(.puzzles)}
    /// Continue opens the next lesson from its start and plays it.
    func continueLesson(){guard learning.lessonIndex+1<learning.library.lessons.count else{return};if (try? transition(.lesson(learning.lessonIndex+1,resume:false)))==true{learning.play()}}
    /// Practise this lesson starts a separate practice game, as White, from the lesson's preset position.
    func practiceLesson(){guard let preset=LessonPractice.forLesson(learning.current.id) else{return};_ = try? transition(.lessonPractice(fen:preset.fen))}
    /// Quitting stops a running lesson translation or recording; the clip in progress is already paid for and is lost.
    /// Returns false when the learner chose to keep the app open. Tests inject an answer; automation never blocks.
    var confirmQuitDuringLessonJob:(()->Bool)?
    func mayQuitDuringLessonJob()->Bool {
        guard lessonLanguages.busy else{return true}
        if let confirm=confirmQuitDuringLessonJob{return confirm()};if NativePolicy.silent{return true}
        let alert=NSAlert();alert.messageText="Stop the lesson job and quit?";alert.informativeText="A lesson \(lessonLanguages.recording ? "recording":"translation") is running. Completed text and clips are kept; the item in progress, already charged, is lost. Record / Resume continues later."
        alert.addButton(withTitle:"Keep Working");let quit=alert.addButton(withTitle:"Quit Anyway");quit.hasDestructiveAction=true
        return alert.runModal() == .alertSecondButtonReturn
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
        let alert=NSAlert();alert.messageText=unsaved==1 ? "A review could not be saved.":"\(unsaved) reviews could not be saved."
        alert.informativeText=(reviewSaveWarning ?? "Its latest imagined lines are only in memory.")+" Cancel to keep working, or quit without them."
        alert.addButton(withTitle:"Cancel");let quit=alert.addButton(withTitle:"Quit Anyway");quit.hasDestructiveAction=true
        return alert.runModal() == .alertSecondButtonReturn
    }
    /// Saves before quitting. A failure offers Export Progress… (the in-memory state) instead of losing the last
    /// moves silently; returns false when the learner chose to stay.
    private func mayQuitAfterSavingProgress()->Bool {
        saveTask?.cancel()
        do{try store.save(session.state);return true}catch{
            if NativePolicy.silent{return true}
            let alert=NSAlert();alert.messageText="Your latest progress could not be saved."
            alert.informativeText=userFacingMessage(error,fallback:"The data folder may be full or read-only.")+" Export it to keep it, or quit without it."
            alert.addButton(withTitle:"Export Progress…");alert.addButton(withTitle:"Cancel");let quit=alert.addButton(withTitle:"Quit Anyway");quit.hasDestructiveAction=true
            switch alert.runModal(){
            case .alertFirstButtonReturn:
                let panel=NSSavePanel();panel.nameFieldStringValue="checkmate-state.json";guard panel.runModal() == .OK,let url=panel.url else{return false}
                do{try store.exportState(session.state,to:url);return true}catch{storageError=userFacingMessage(error,fallback:"The export could not be written. Choose another location.");return false}
            case .alertThirdButtonReturn:return true
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
        let branches=review.branchesForSaving,ideas=branches.count;guard ideas>0 else{return true}
        if let approved=draftDiscardApproved,approved.id==id,approved.branches==branches{return true}
        switch askAboutDraft?(ideas) ?? askLearnerAboutDraft(ideas) {
        case .discard:draftDiscardApproved=(id,branches);return true
        case .cancel:return false
        case .save:return saveDraft()
        }
    }
    private func askLearnerAboutDraft(_ ideas:Int)->DraftDisposal {
        if NativePolicy.silent{return .discard}
        let alert=NSAlert();alert.messageText="Save this review before leaving?"
        alert.informativeText="It holds \(ideas) imagined line\(ideas==1 ? "":"s") of yours that will be lost if you don’t save."
        alert.addButton(withTitle:"Save");let discard=alert.addButton(withTitle:"Don’t Save");discard.hasDestructiveAction=true;alert.addButton(withTitle:"Cancel")
        switch alert.runModal(){case .alertFirstButtonReturn:return .save;case .alertSecondButtonReturn:return .discard;default:return .cancel}
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
        guard !review.active else{throw CheckmateError.invalid("Leave the open review, then import the progress file again.")}
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
                let archive=try Data(contentsOf:url);var state=self.session.state
                let report=try LegacyImporter.apply(archive,to:&state,course:self.learning.library)
                let alert=NSAlert()
                if report.duplicate {alert.messageText="Already imported";alert.informativeText=report.summary;alert.runModal();return}
                alert.messageText="Import game and progress?"
                alert.informativeText=report.summary+" A separate copy of your current state will be kept in Backups."
                let text=NSTextView(frame:NSRect(x:0,y:0,width:480,height:180));text.string=report.details;text.isEditable=false;text.isSelectable=true;text.font = .systemFont(ofSize:NSFont.systemFontSize);text.textContainerInset=NSSize(width:8,height:8);text.setAccessibilityLabel("Import recovery report")
                let scroll=NSScrollView(frame:text.frame);scroll.hasVerticalScroller=true;scroll.borderType = .noBorder;scroll.documentView=text;alert.accessoryView=scroll
                alert.addButton(withTitle:"Import");alert.addButton(withTitle:"Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else{return}
                if self.review.active || self.reviewWorkspace{guard self.returnToGame() else{return}}
                state=self.session.state
                let finalReport=try LegacyImporter.apply(archive,to:&state,course:self.learning.library)
                if finalReport.duplicate{return}
                let backup=try self.installImport(state)
                let result=NSAlert();result.messageText="Progress imported";result.informativeText=finalReport.summary;result.addButton(withTitle:"Done");result.addButton(withTitle:"Show Backup")
                if result.runModal() == .alertSecondButtonReturn {NSWorkspace.shared.activateFileViewerSelecting([backup])}
            }catch {self.storageError=userFacingMessage(error,fallback:"The progress file could not be imported. Your current progress is unchanged.")}
        }
    }
    /// Leaves a review (or the workspace) for the place it was opened over, resuming that place.
    @discardableResult func returnToGame()->Bool{(try? transition(.returnToGame)) ?? false}
    func showReviewWorkspace(){_ = try? transition(.reviewWorkspace)}
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
                let result=Result{try reviewSaves.flush(snapshot.document,cursor:snapshot.cursor,branches:snapshot.branches)}
                finishReviewSave(id,snapshot:snapshot,result:result)
                if pendingReviewSnapshots[id] != nil,!review.active || review.document?.id==id{saved=false}
            }
            return saved
        }
        guard !shuttingDown else{return false}
        let snapshots=pendingReviewSnapshots
        reviewSaveTask=Task{[weak self] in try? await Task.sleep(for:.milliseconds(250));guard let self,!Task.isCancelled,!self.shuttingDown else{return}
            for (id,snapshot) in snapshots {
                self.reviewSaves.save(snapshot.document,cursor:snapshot.cursor,branches:snapshot.branches){[weak self] result in Task{@MainActor in
                    guard let self=self,!self.shuttingDown,self.reviewSaveGeneration==generation else{return}
                    self.finishReviewSave(id,snapshot:snapshot,result:result)
                }}
            }
        }
        return true
    }
    private func finishReviewSave(_ id:UUID,snapshot:ReviewSnapshot,result:Result<[ReviewIndexEntry],Error>){
        switch result {
        case .success(let entries):reviews=entries;writtenReviewSnapshots[id]=snapshot;if pendingReviewSnapshots[id]==snapshot{pendingReviewSnapshots[id]=nil}
        case .failure(CheckmateError.cancelled):pendingReviewSnapshots[id]=nil  // the record was deleted
        case .failure(let error):let warning=Self.reviewSaveFailure(error);reviewSaveWarning=warning;storageError=warning
        }
        if pendingReviewSnapshots.isEmpty,let warning=reviewSaveWarning{if storageError==warning{storageError=nil};reviewSaveWarning=nil}
    }
    /// Returns whether the review is open with its state restored; false when the learner kept a draft, the request was
    /// withdrawn while the draft question was up (`stillWanted`), or the restore failed.
    @discardableResult func openReview(_ document:GameDocument,saved:SavedReview?=nil,draft:Bool=false,stillWanted:()->Bool={true})->Bool{
        (try? transition(.review(document,saved:saved,draft:draft),stillWanted:stillWanted)) ?? false
    }
    // MARK: Activity transitions (B8.2)
    /// A request to go somewhere else. Each case carries what its entry needs, so the commands that all end in practice
    /// (Practice a game, Return to game, an import, a practice fork) keep their own meaning.
    enum Navigation {
        case practice,returnToGame,lesson(Int,resume:Bool=true),puzzles,reviewWorkspace
        /// A lesson's own practice position, played as White in a separate game.
        case lessonPractice(fen:String)
        case review(GameDocument,saved:SavedReview?,draft:Bool)
        case importProgress(ApplicationState,backup:(URL)->Void)
        case practiceFork(side:String,preset:String)
    }
    /// What a staged entry needs once the current activity has been left.
    private enum Staged {case none,lessonPractice(ChessRules),review(GameDocument,restore:(cursor:Int,branches:[ReviewBranch])?),importProgress(ApplicationState),practiceFork(ChessRules)}
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
        // 1. The learner's say.
        if case .practiceFork=next,!practiceForkStillCurrent(){return false}
        guard sameReview || resolveDraftBeforeLeaving() else{return false}
        // A "Don't save" answered this request only: withdrawn, or overtaken by another navigation made while the question
        // was up (an agent's call runs during the modal), the draft stays and the next exit asks again.
        guard stillWanted(),reviewOpenGeneration==token else{draftDiscardApproved=nil;return false}
        // The draft question is modal and main-actor work (an agent's review call) runs during it: check the position again.
        if case .practiceFork=next,!practiceForkStillCurrent(){draftDiscardApproved=nil;return false}
        // 2. Staging.
        let staged:Staged
        switch next {
        case .review(let document,let saved,_):
            // A record whose last save failed reopens as it was left, never as its older file; that state is saved again on entry.
            let pending=pendingReviewSnapshots[document.id],shown=pending?.document ?? document
            let restore=pending.map{(cursor:$0.cursor,branches:$0.branches)} ?? saved.map{(cursor:$0.cursor,branches:$0.branches)}
            guard restore.map({shown.nodes.indices.contains($0.cursor)}) ?? true else{
                // A failed restore changes nothing, and never resumes play by itself (plan rule 4): a practice reply
                // waiting here is held for the explicit Return to game shown with the error.
                draftDiscardApproved=nil;let waiting=reviewing ? false:session.requireExplicitResume()
                storageError=waiting ? Self.failedRestorePausedMessage:Self.failedRestoreMessage;return false}
            staged = .review(shown,restore:restore)
        case .importProgress(let state,_):try StateStore.validate(state);staged = .importProgress(state)
        case .practiceFork(let side,_):
            do{let rules=try review.practiceForkRules()
                guard !rules.over else{throw CheckmateError.invalid("This position is terminal and cannot start practice.")}
                try GameSession.validatePracticeFork(rules,side:side);try ChessRules().restore(rules.pgn);staged = .practiceFork(rules)}
            catch{practiceForkRequested=false;draftDiscardApproved=nil;storageError=userFacingMessage(error,fallback:"Practice could not start from this position. The review is unchanged.");return false}
        case .lessonPractice(let fen):
            do{let rules=try ChessRules(fen:fen);try GameSession.validatePracticeFork(rules,side:"w");staged = .lessonPractice(rules)}
            catch{draftDiscardApproved=nil;storageError=userFacingMessage(error,fallback:"This practice position could not be opened.");return false}
        default:staged = .none
        }
        // The backup that an import or a fork keeps is the last staged step: it is written only for an entry that will happen.
        switch (next,staged) {
        // The imported state is written here too: a write that fails leaves playback, connections and the activity alone.
        case (.importProgress(_,let backup),.importProgress(let state)):backup(try store.preserveBeforeImport(session.state));try store.save(state)
        case (.practiceFork,.practiceFork):do{_ = try store.preserveBeforeImport(session.state)}catch{practiceForkRequested=false;draftDiscardApproved=nil;storageError=userFacingMessage(error,fallback:"Practice could not start from this position. The review is unchanged.");return false}
        default:break
        }
        // 3. Exit.
        reviewOpenGeneration+=1;cancelReviewImport();practiceForkRequested=false;practiceForkIdentity=nil
        // Every way out of a review, and every review shown, starts with no whole-game analysis holding the engine (PL-1).
        let entersReview:Bool={if case .review=next{return true};return false}()
        if reviewing || entersReview{reviewAnalyzer.reset()}
        // The open review is saved and closed unless it is the one being shown again.
        if review.active && !sameReview{let saved=saveReview(immediate:true);review.unload();forgetFlushedReview(saved)}
        switch next {
        case .returnToGame:break
        case .practice:if !reviewing{learning.pause()};audio.stop()
        case .lesson,.puzzles:voice.disconnect();audio.stop()
        case .lessonPractice:learning.pause();voice.disconnect();audio.stop()
        case .reviewWorkspace,.review:learning.pause();voice.disconnect();audio.stopAll()
        case .importProgress:saveTask?.cancel();voice.disconnect();usage.flushForShutdown();companion.disable();learning.pause();audio.stopAll()
        case .practiceFork:session.cancelWork()
        }
        // 4. Entry.
        switch (next,staged) {
        case (.practice,_):
            if reviewing{session.enter(.at(.practice),resume:place == .practice)}else if place == .practice{session.resumeHeldReply()}else{session.enter(.at(.practice))}
        // Outside a review, Return to game is still the explicit resume of a held practice reply (a failed restore).
        case (.returnToGame,_):if reviewing{session.enter(.at(place),resume:true)}else if place == .practice{session.resumeHeldReply()};learning.resumeMiniOpponent()
        case (.lesson(let index,let resume),_):if reviewing{session.enter(.at(place));session.cancelWork()};learning.openLesson(index:index,resume:resume)
        case (.puzzles,_):if reviewing{session.enter(.at(place));session.cancelWork()};learning.showPuzzleLibrary()
        case (.reviewWorkspace,_):session.enter(.reviewing(ReviewVisit(document:nil,draft:false,returnTo:place)))
        case (.review(let document,_,let draft),.review(let shown,let restore)):
            restoringReview=true;review.load(shown);session.enter(.reviewing(ReviewVisit(document:document.id,draft:draft,returnTo:place)));draftDiscardApproved=nil
            if let restore{try? review.restoreSaved(cursor:restore.cursor,branches:restore.branches)}
            restoringReview=false;saveReview();onReview?()
        case (.importProgress,.importProgress(let state)):
            do{try session.installImportedState(state)}catch{if session.activity.review != nil{session.enter(.at(place))};throw error}
            learning.reloadFilters();onImport?()
        case (.practiceFork(let side,let preset),.practiceFork(let rules)):
            let previous=session.state.settings;var settings=previous;settings.opponentPreset=preset;session.updateSettings(settings,restartOpponent:false)
            do{try session.installPracticeFork(rules,side:side)}catch{
                session.updateSettings(previous,restartOpponent:false);if session.activity.review != nil{session.enter(.at(place))}
                storageError=userFacingMessage(error,fallback:"Practice could not start from this position. The review was closed; your game is unchanged.");return false}
        case (.lessonPractice,.lessonPractice(let rules)):
            do{try session.installPracticeFork(rules,side:"w")}catch{
                if session.activity.review != nil{session.enter(.at(place))};storageError=userFacingMessage(error,fallback:"This practice position could not be opened.");return false}
        default:break
        }
        return true
    }
    func openSavedReview(_ id:UUID){
        reviewOpenGeneration+=1;cancelReviewImport();let generation=reviewOpenGeneration
        guard !shuttingDown,review.document?.id != id,resolveDraftBeforeLeaving() else{return}
        let store=reviewStore,delay=NativePolicy.silent ? min(2000,max(0,automationReviewLoadDelayMs)):0
        importingReview=true
        reviewImportTask=Task{do{
            if delay>0{try await Task.sleep(for:.milliseconds(delay))}
            let saved=try await Task.detached{try store.load(id)}.value
            guard !Task.isCancelled,!shuttingDown,reviewOpenGeneration==generation else{return};importingReview=false
            openReview(saved.document,saved:saved)
        }catch{guard !Task.isCancelled,!shuttingDown,reviewOpenGeneration==generation else{return};importingReview=false;draftDiscardApproved=nil;storageError="The saved review could not be opened; its file is preserved."}}
    }
    func requestDeleteReview(_ id:UUID){
        guard deletingReviewID==nil,let record=reviews.first(where:{$0.id==id}) else{return}
        let alert=NSAlert();alert.messageText="Delete “\(record.title)”?"
        alert.informativeText="This removes the saved review and its imagined lines. Your current game and the original imported file are kept."
        let delete=alert.addButton(withTitle:"Delete");delete.keyEquivalent=""
        let cancel=alert.addButton(withTitle:"Cancel");cancel.keyEquivalent="\r"
        alert.window.defaultButtonCell=cancel.cell as? NSButtonCell
        if let window=NSApp.mainWindow{alert.beginSheetModal(for:window){[weak self] response in if response == .alertFirstButtonReturn{self?.deleteReview(id)}}}
        else if alert.runModal() == .alertFirstButtonReturn{deleteReview(id)}
    }
    func deleteReview(_ id:UUID){
        guard deletingReviewID==nil else{return}
        // A saved review still loading is abandoned with its "Loading review…" overlay, never left showing it.
        deletingReviewID=id;reviewLibraryGeneration+=1;reviewOpenGeneration+=1;cancelReviewImport()
        reviewSaveGeneration+=1;reviewSaveTask?.cancel()
        let writer=reviewSaves
        Task {
            do {
                let entries=try await Task.detached{try writer.delete(id)}.value
                pendingReviewSnapshots[id]=nil
                if review.document?.id==id{_ = try? transition(.returnToGame)}
                reviews=entries;deletingReviewID=nil
                if review.active{saveReview()}
                // The deleted review's engine analysis goes with it; a failure only leaves files for LRU eviction.
                try? await reviewAnalyzer.forgetAnalysis(documentID:id)
            } catch {
                deletingReviewID=nil
                storageError="The review could not be deleted. Its saved record is preserved; try again."
                if review.active{saveReview()}
            }
        }
    }
    /// The game's text is read here; parsing it (seconds for a long game) runs detached, under the import overlay and its Cancel.
    func reviewCurrent(previous:Bool=false){
        reviewOpenGeneration+=1;cancelReviewImport();let generation=reviewOpenGeneration,provenance=previous ? "Previous game":"Current game",fallback="This game could not be opened for review. Your practice is unchanged."
        let data:Data;do{data=previous ? try ReviewRecordSource.data(previousGame:session.state.practice.previousGame,result:session.state.practice.previousEnding?.result):try ReviewRecordSource.data(session.rules,result:session.state.practice.ending?.result)}catch{storageError=userFacingMessage(error,fallback:fallback);return}
        let token=ReviewImportCancellation();reviewImportCancellation=token;importingReview=true
        reviewImportTask=Task{do{let document=try await Task.detached{try PGNImporter.parse(data,provenance:provenance,cancelled:{token.cancelled})[0]}.value;guard !Task.isCancelled,reviewOpenGeneration==generation else{return};importingReview=false;openReview(document,draft:true)}catch{guard !Task.isCancelled else{return};importingReview=false;storageError=userFacingMessage(error,fallback:fallback)}}
    }
    func importReviewData(_ data:Data){reviewOpenGeneration+=1;cancelReviewImport();cancelReviewImport();let token=ReviewImportCancellation();reviewImportCancellation=token;importingReview=true;let delay=NativePolicy.silent ? min(2000,max(0,automationReviewImportDelayMs)):0;reviewImportTask=Task{do{if delay>0{try await Task.sleep(for:.milliseconds(delay))};let report=try await withTaskCancellationHandler(operation:{try await Task.detached{try PGNImporter.parseReport(data,cancelled:{token.cancelled || Task.isCancelled})}.value},onCancel:{token.cancel()});guard !Task.isCancelled else{return};importingReview=false;let documents=report.documents;guard !documents.isEmpty else{throw CheckmateError.invalid("No games found in this record.")}
                // Unreadable games in a collection are skipped, and the learner is told which.
                if let first=report.skipped.first{storageError="\(report.skipped.count) game\(report.skipped.count==1 ? "":"s") in this file could not be read and \(report.skipped.count==1 ? "was":"were") skipped. "+(first.errorDescription ?? "")}
                if documents.count==1{openReview(documents[0],draft:true)}else{let alert=NSAlert();alert.messageText="Choose a game to review";let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:440,height:28));picker.setAccessibilityLabel("Game to review");for (recordIndex,d) in documents.enumerated(){let label="\(recordIndex+1). \(d.header("White") ?? "White") – \(d.header("Black") ?? "Black") · \(d.result) · \(d.header("Date") ?? "Unknown date")";picker.addItem(withTitle:String(label.prefix(256)))};alert.accessoryView=picker;alert.addButton(withTitle:"Review");alert.addButton(withTitle:"Cancel")
                // Main-actor work (MCP, saved loads, timers) can run during the modal loop; a choice made
                // after another activity was selected must not replace it.
                let chooserGeneration=reviewOpenGeneration;let response=alert.runModal()
                guard !Task.isCancelled,reviewOpenGeneration==chooserGeneration else{return}
                if response == .alertFirstButtonReturn{openReview(documents[picker.indexOfSelectedItem],draft:true)}}}catch{guard !Task.isCancelled else{return};importingReview=false;storageError=userFacingMessage(error,fallback:"This record could not be imported. Your current game and reviews are unchanged.")}}}
    /// Every exit that asked about a draft finishes at once except a saved review's load, so a cancelled load also
    /// spends that answer.
    /// A review file the learner just chose starts reading: it replaces any older open or import still running, so an
    /// earlier file's parse cannot finish first and take over.
    func supersedeReviewOpen(){reviewOpenGeneration+=1;cancelReviewImport()}
    func cancelReviewImport(){draftDiscardApproved=nil;reviewImportCancellation?.cancel();reviewImportCancellation=nil;reviewImportTask?.cancel();reviewImportTask=nil;importingReview=false}
    func openPGN(){let panel=NSOpenPanel();panel.allowsOtherFileTypes=true;panel.allowsMultipleSelection=false;panel.begin{response in guard response == .OK,let url=panel.url else{return};do{let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=ReviewPolicy.maximumBytes else{throw CheckmateError.invalid("File exceeds 16 MiB.")};self.importReviewData(try Data(contentsOf:url))}catch{self.storageError=userFacingMessage(error,fallback:"The selected file could not be read. Your current game and reviews are unchanged.")}}}
    func pasteReview(){guard let text=NSPasteboard.general.string(forType:.string) else{storageError="Copy PGN or FEN text first.";return};importReviewData(Data(text.utf8))}
    func exportReview(){
        guard let d=review.document else{return};let branches=review.branchesForSaving
        let panel=NSSavePanel();panel.nameFieldStringValue=Self.exportName(d,ideas:false)
        let choice=NSPopUpButton(frame:NSRect(x:0,y:0,width:260,height:28));choice.addItems(withTitles:["Original record","Original and my imagined lines"]);choice.setAccessibilityLabel("Export contents")
        // A FEN-only original exports as FEN; adding ideas always produces PGN records.
        let naming=ExportNaming(panel:panel,document:d);choice.target=naming;choice.action=#selector(ExportNaming.choiceChanged(_:))
        if branches.contains(where:{!$0.moves.isEmpty}){panel.accessoryView=choice}
        panel.begin{response in withExtendedLifetime(naming){};guard response == .OK,let url=panel.url else{return};let ideas=choice.indexOfSelectedItem==1
            // Each idea replays its history in a new chess.js context: build and write the file off the main thread.
            Task{do{try await Task.detached{try (ideas ? PGNExporter.withIdeas(d,branches:branches):d.original).write(to:url,options:.atomic)}.value}catch{self.storageError="The review could not be exported."}}}
    }
    /// The sheet forks the position it was opened for (RV-11): any transition ends the request, and a review changed
    /// under the sheet (open, paste, an agent) is refused.
    private var practiceForkIdentity:String?
    func practiceFromReview(){practiceForkIdentity=review.identity+":\(review.branchPly)";practiceForkRequested=true}
    private func practiceForkStillCurrent()->Bool {
        guard practiceForkRequested,review.active,practiceForkIdentity==review.identity+":\(review.branchPly)" else{practiceForkRequested=false;practiceForkIdentity=nil;storageError="The review changed while you were choosing. Choose Practise here again.";return false};return true}
    /// Forks exactly the displayed position: an imagined line replays from its own root (for "Compare best line", the
    /// parent), with history-aware automatic terminal rules.
    func confirmPracticeFork(side:String,preset:String){_ = try? transition(.practiceFork(side:side,preset:preset))}
    static func exportName(_ document:GameDocument,ideas:Bool)->String {document.historyAvailable || ideas ? "review.pgn":"review.fen"}
    func showBackups(){NSWorkspace.shared.activateFileViewerSelecting([store.directory])}
    func exportState(){let panel=NSSavePanel();panel.nameFieldStringValue="checkmate-state.json";panel.begin {response in guard response == .OK,let url=panel.url else{return};do{try self.store.exportState(self.session.state,to:url)}catch{self.storageError=userFacingMessage(error,fallback:"The export could not be written. Choose another location.")}}}
    func shutdown(){lessonLanguages.shutdown();connectionStartup?.cancel();reviewTools.reset();reviewOpenGeneration+=1;cancelReviewImport();saveReview(immediate:true);shuttingDown=true;cancelReviewImport();reviewSaveTask?.cancel();review.cancel();saveTask?.cancel();soundTasks.values.forEach{$0.cancel()};session.prepareShutdown();voice.disconnect();usage.flushForShutdown();companion.disable();learning.shutdown();audio.stopAll();session.cancelWork();try? store.save(session.state)}
}
/// Keeps the Save panel's suggested extension consistent with the chosen export contents.
@MainActor final class ExportNaming:NSObject {
    weak var panel:NSSavePanel?;let document:GameDocument
    init(panel:NSSavePanel,document:GameDocument){self.panel=panel;self.document=document}
    @objc func choiceChanged(_ sender:NSPopUpButton){
        guard let panel=panel else{return};let name=NativeModel.exportName(document,ideas:sender.indexOfSelectedItem==1)
        let stem=(panel.nameFieldStringValue as NSString).deletingPathExtension;panel.nameFieldStringValue=(stem.isEmpty ? "review":stem)+"."+(name as NSString).pathExtension
    }
}
