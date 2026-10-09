import AppKit
import UniformTypeIdentifiers
import Combine
import CheckmateCore
@MainActor final class NativeModel:ObservableObject {
    let session:GameSession,learning:LearningPlayer,audio:NativeAudio,store:StateStore
    let companion:CompanionBroker,voice:VoiceCoach
    let review=ReviewController()
    let reviewStore:ReviewStore,reviewAnalyzer:ReviewAnalyzer
    @Published var reviews:[ReviewIndexEntry]=[]
    @Published var importingReview=false
    @Published var practiceForkRequested=false
    private var reviewImportTask:Task<Void,Never>?
    private var reviewImportCancellation:ReviewImportCancellation?
    private struct ReviewSnapshot {let document:GameDocument,cursor:Int,branches:[ReviewBranch]}
    private var pendingReviewSnapshot:ReviewSnapshot?
    private var reviewSaveGeneration=0
    private var reviewOpenGeneration=0
    var automationReviewLoadDelayMs=0
    var automationReviewImportDelayMs=0
    private var restoringReview=false
    private let reviewSaves:ReviewSaveCoordinator
    private static let reviewSaveFailure="The review could not be saved; export the original PGN before quitting."
    private var reviewSaveTask:Task<Void,Never>?
    private static let progressSaveFailure="Your progress could not be saved. Export it before quitting."
    private var shuttingDown=false
    var onReview:(()->Void)?
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
        store=StateStore(directory:StateStore.defaultDirectory());let state=try store.load();store.preserveFirstLaunchBackup()
        let engine=NativeEngine();reviewAnalyzer=ReviewAnalyzer(engine:engine,cacheDirectory:store.directory.appendingPathComponent("ReviewAnalysis"));reviewStore=ReviewStore(directory:store.directory.appendingPathComponent("Reviews"))
        reviewSaves=ReviewSaveCoordinator(store:reviewStore)
        session=try GameSession(engine:engine,state:state);learning=try LearningPlayer(session:session);audio=NativeAudio(scores:learning.library.sounds);learning.audio=audio
        companion=try CompanionBroker(session:session,directory:store.directory.appendingPathComponent("companion"));voice=try VoiceCoach(session:session)
        session.reviewController=review;voice.attachReview(review)
        let reviewTools=ReviewTools(review:review,session:session,store:reviewStore,analyzer:reviewAnalyzer);reviewTools.onOpen={[weak self] document in self?.openReview(document)};reviewTools.onPractice={[weak self] in self?.practiceForkRequested=true};companion.tools.reviewTools=reviewTools;self.reviewTools=reviewTools
        reviewTools.activityGeneration={[weak self] in self?.reviewOpenGeneration ?? -1}
        session.onPersist={[weak self] state in guard let self=self else{return};self.saveTask?.cancel();self.saveTask=Task{try? await Task.sleep(nanoseconds:250_000_000);guard !Task.isCancelled else{return};do{try self.store.save(state);if self.storageError==Self.progressSaveFailure{self.storageError=nil}}catch{NativeLog.storage.error("State save failed; export remains available");self.storageError=Self.progressSaveFailure}}}
        learning.onIllustration={[weak self] piece,capture in guard let self=self else{return};self.audio.illustration(piece:piece,capture:capture,settings:self.session.state.settings)}
        session.onMove={[weak self] move in guard let self=self else{return};let settings=self.session.state.settings;let delay=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:settings.pieceDuration;let id=UUID();self.soundTasks[id]=Task{defer{self.soundTasks.removeValue(forKey:id)};try? await Task.sleep(nanoseconds:UInt64(delay)*1_000_000);guard !Task.isCancelled else{return};self.audio.move(move,settings:settings)}}
        learning.onMiniMove=session.onMove
        learning.onMiniReset={[weak self] in self?.soundTasks.values.forEach{$0.cancel()};self?.soundTasks=[:]}
        session.onUndo={[weak self] in guard let self=self else{return};self.soundTasks.values.forEach{$0.cancel()};self.soundTasks=[:];self.audio.move(nil,settings:self.session.state.settings,undo:true)}
        let reviewStore=reviewStore;Task{do{reviews=try await Task.detached{try reviewStore.list()}.value}catch{storageError="Saved reviews could not be loaded. Your current practice is unchanged."}}
        review.onEvent={[weak self] in self?.session.signalEvent();self?.saveReview()}
        // The banner observes this model; forward gate changes, and drop the paused sentence once the held game resumed or changed.
        session.$explicitResumeRequired.removeDuplicates().dropFirst().receive(on:RunLoop.main).sink{[weak self] held in guard let self=self else{return};self.objectWillChange.send();if !held,self.storageError==Self.failedRestorePausedMessage{self.storageError=Self.failedRestoreMessage}}.store(in:&observations)
        session.$state.map(\.settings).removeDuplicates().dropFirst().receive(on:RunLoop.main).sink {[weak self] _ in self?.learning.settingsChanged();self?.voice.settingsChanged()}.store(in:&observations)
    }
    func practice(){reviewOpenGeneration+=1;cancelReviewImport();if review.active{returnToGame()};learning.pause();audio.stop();session.resumePractice();if session.state.settings.voiceAutoConnect && !NativePolicy.silent && !companion.enabled{voice.connect()}}
    func lesson(_ index:Int){leaveReviewForActivity();voice.disconnect();audio.stop();learning.openLesson(index:index)}
    func puzzles(){leaveReviewForActivity();voice.disconnect();audio.stop();learning.showPuzzleLibrary()}
    func installImport(_ state:ApplicationState)throws -> URL {
        reviewOpenGeneration+=1;cancelReviewImport()
        try StateStore.validate(state)
        let backup=try store.preserveBeforeImport(session.state)
        saveTask?.cancel();voice.disconnect();companion.disable();learning.pause();audio.stopAll()
        try store.save(state);try session.installImportedState(state);learning.reloadFilters();onImport?();return backup
    }
    func importState(){
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
                state=self.session.state
                let finalReport=try LegacyImporter.apply(archive,to:&state,course:self.learning.library)
                if finalReport.duplicate{return}
                let backup=try self.installImport(state)
                let result=NSAlert();result.messageText="Progress imported";result.informativeText=finalReport.summary;result.addButton(withTitle:"Done");result.addButton(withTitle:"Show Backup")
                if result.runModal() == .alertSecondButtonReturn {NSWorkspace.shared.activateFileViewerSelecting([backup])}
            }catch {self.storageError=userFacingMessage(error,fallback:"The progress file could not be imported. Your current progress is unchanged.")}
        }
    }
    func leaveReviewForActivity(){reviewOpenGeneration+=1;cancelReviewImport();reviewAnalyzer.reset();guard review.active else{return};let saved=saveReview(immediate:true);review.close(practice:session,resumePractice:false);session.cancelWork();forgetFlushedReview(saved)}
    func returnToGame(){reviewOpenGeneration+=1;cancelReviewImport();reviewAnalyzer.reset();let saved=saveReview(immediate:true);review.close(practice:session);forgetFlushedReview(saved)}
    /// A review durably flushed on close is not re-saved by later debounces or quit; a failed flush stays pending for retry.
    private func forgetFlushedReview(_ saved:Bool){guard saved,!review.active else{return};reviewSaveTask?.cancel();reviewSaveTask=nil;pendingReviewSnapshot=nil}
    @discardableResult func saveReview(immediate:Bool=false)->Bool{
        guard !restoringReview else{return false}
        if let document=review.document{pendingReviewSnapshot=ReviewSnapshot(document:document,cursor:review.nodeID,branches:review.branchesForSaving)}
        guard let snapshot=pendingReviewSnapshot else{return true}
        reviewSaveTask?.cancel();reviewSaveGeneration+=1;let generation=reviewSaveGeneration
        if immediate {
            do{reviews=try reviewSaves.flush(snapshot.document,cursor:snapshot.cursor,branches:snapshot.branches);if storageError==Self.reviewSaveFailure{storageError=nil};return true}
            catch{storageError=Self.reviewSaveFailure;return false}
        }
        guard !shuttingDown else{return false}
        reviewSaveTask=Task{try? await Task.sleep(for:.milliseconds(250));guard !Task.isCancelled,!shuttingDown else{return}
            reviewSaves.save(snapshot.document,cursor:snapshot.cursor,branches:snapshot.branches){[weak self] result in Task{@MainActor in
                guard let self=self,!self.shuttingDown,self.reviewSaveGeneration==generation else{return}
                switch result{case .success(let entries):self.reviews=entries;if self.storageError==Self.reviewSaveFailure{self.storageError=nil};case .failure:self.storageError=Self.reviewSaveFailure}
            }}
        }
        return true
    }
    func openReview(_ document:GameDocument,saved:SavedReview?=nil){
        reviewOpenGeneration+=1;cancelReviewImport()
        guard ReviewRolloutPolicy.reviewEnabled else{storageError="Game review is disabled by the current rollout policy.";return}
        saveReview(immediate:true);learning.pause();voice.disconnect();audio.stopAll();restoringReview=true
        review.open(document,practice:session);reviewAnalyzer.reset()
        do{if let saved=saved{try review.restoreSaved(cursor:saved.cursor,branches:saved.branches)}}
        // A failed restore returns the exact prior owner but never resumes play by itself (plan rule 4): a suspended
        // practice reply waits for the explicit "Return to game" action shown with the error.
        catch{let waiting=review.abandonFailedEntry(practice:session);restoringReview=false
            storageError=waiting ? Self.failedRestorePausedMessage:Self.failedRestoreMessage;return}
        restoringReview=false;saveReview();onReview?()
    }
    func openSavedReview(_ id:UUID){
        reviewOpenGeneration+=1;cancelReviewImport();let generation=reviewOpenGeneration
        guard !shuttingDown,review.document?.id != id else{return}
        let store=reviewStore,delay=NativePolicy.silent ? min(2000,max(0,automationReviewLoadDelayMs)):0
        Task{do{
            if delay>0{try await Task.sleep(for:.milliseconds(delay))}
            let saved=try await Task.detached{try store.load(id)}.value
            guard !shuttingDown,reviewOpenGeneration==generation else{return}
            openReview(saved.document,saved:saved)
        }catch{guard !shuttingDown,reviewOpenGeneration==generation else{return};storageError="The saved review could not be opened; its file is preserved."}}
    }
    func reviewCurrent(previous:Bool=false){do{let data=previous ? try ReviewRecordSource.data(previousGame:session.state.practice.previousGame):try ReviewRecordSource.data(session.rules);openReview(try PGNImporter.parse(data,provenance:previous ? "Previous game":"Current game")[0])}catch{storageError=userFacingMessage(error,fallback:"This game could not be opened for review. Your practice is unchanged.")}}
    func importReviewData(_ data:Data){reviewOpenGeneration+=1;cancelReviewImport();cancelReviewImport();let token=ReviewImportCancellation();reviewImportCancellation=token;importingReview=true;let delay=NativePolicy.silent ? min(2000,max(0,automationReviewImportDelayMs)):0;reviewImportTask=Task{do{if delay>0{try await Task.sleep(for:.milliseconds(delay))};let documents=try await withTaskCancellationHandler(operation:{try await Task.detached{try PGNImporter.parse(data,cancelled:{token.cancelled || Task.isCancelled})}.value},onCancel:{token.cancel()});guard !Task.isCancelled else{return};importingReview=false;guard !documents.isEmpty else{throw CheckmateError.invalid("No games found in this record.")};if documents.count==1{openReview(documents[0])}else{let alert=NSAlert();alert.messageText="Choose a game to review";let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:440,height:28));picker.setAccessibilityLabel("Game to review");for (recordIndex,d) in documents.enumerated(){let label="\(recordIndex+1). \(d.header("White") ?? "White") – \(d.header("Black") ?? "Black") · \(d.result) · \(d.header("Date") ?? "Unknown date")";picker.addItem(withTitle:String(label.prefix(256)))};alert.accessoryView=picker;alert.addButton(withTitle:"Review");alert.addButton(withTitle:"Cancel")
                // Main-actor work (MCP, saved loads, timers) can run during the modal loop; a choice made
                // after another activity was selected must not replace it.
                let chooserGeneration=reviewOpenGeneration;let response=alert.runModal()
                guard !Task.isCancelled,reviewOpenGeneration==chooserGeneration else{return}
                if response == .alertFirstButtonReturn{openReview(documents[picker.indexOfSelectedItem])}}}catch{guard !Task.isCancelled else{return};importingReview=false;storageError=userFacingMessage(error,fallback:"This record could not be imported. Your current game and reviews are unchanged.")}}}
    func cancelReviewImport(){reviewImportCancellation?.cancel();reviewImportCancellation=nil;reviewImportTask?.cancel();reviewImportTask=nil;importingReview=false}
    func openPGN(){let panel=NSOpenPanel();panel.allowsOtherFileTypes=true;panel.allowsMultipleSelection=false;panel.begin{response in guard response == .OK,let url=panel.url else{return};do{let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=ReviewPolicy.maximumBytes else{throw CheckmateError.invalid("File exceeds 16 MiB.")};self.importReviewData(try Data(contentsOf:url))}catch{self.storageError=userFacingMessage(error,fallback:"The selected file could not be read. Your current game and reviews are unchanged.")}}}
    func pasteReview(){guard let text=NSPasteboard.general.string(forType:.string) else{storageError="Copy PGN or FEN text first.";return};importReviewData(Data(text.utf8))}
    func exportReview(){
        guard let d=review.document else{return};let branches=review.branchesForSaving
        let panel=NSSavePanel();panel.nameFieldStringValue=Self.exportName(d,ideas:false)
        let choice=NSPopUpButton(frame:NSRect(x:0,y:0,width:260,height:28));choice.addItems(withTitles:["Original record","Original and my imagined lines"]);choice.setAccessibilityLabel("Export contents")
        // A FEN-only original exports as FEN; adding ideas always produces PGN records.
        let naming=ExportNaming(panel:panel,document:d);choice.target=naming;choice.action=#selector(ExportNaming.choiceChanged(_:))
        if branches.contains(where:{!$0.moves.isEmpty}){panel.accessoryView=choice}
        panel.begin{response in withExtendedLifetime(naming){};guard response == .OK,let url=panel.url else{return};do{let data=choice.indexOfSelectedItem==1 ? try PGNExporter.withIdeas(d,branches:branches):d.original;try data.write(to:url,options:.atomic)}catch{self.storageError="The review could not be exported."}}
    }
    func practiceFromReview(){practiceForkRequested=true}
    func confirmPracticeFork(side:String,preset:String){
        reviewOpenGeneration+=1;cancelReviewImport()
        guard review.active else{return}
        // Fork exactly the displayed position: an imagined line replays from its own root
        // (for "Compare best line", the parent), with history-aware automatic terminal rules.
        do{let rules=try review.practiceForkRules()
            guard !rules.over else{throw CheckmateError.invalid("This position is terminal and cannot start practice.")}
            try GameSession.validatePracticeFork(rules,side:side);_ = try store.preserveBeforeImport(session.state);let saved=saveReview(immediate:true);review.close(practice:session,resumePractice:false);session.cancelWork();forgetFlushedReview(saved)
            var settings=session.state.settings;settings.opponentPreset=preset;session.updateSettings(settings,restartOpponent:false)
            try session.installPracticeFork(rules,side:side);practiceForkRequested=false
        }catch{storageError=userFacingMessage(error,fallback:"Practice could not start from this position. The review is unchanged.")}
    }
    static func exportName(_ document:GameDocument,ideas:Bool)->String {document.historyAvailable || ideas ? "review.pgn":"review.fen"}
    func showBackups(){NSWorkspace.shared.activateFileViewerSelecting([store.directory])}
    func exportState(){let panel=NSSavePanel();panel.nameFieldStringValue="checkmate-state.json";panel.begin {response in guard response == .OK,let url=panel.url else{return};do{try self.store.save(self.session.state);try self.store.export(to:url)}catch{self.storageError="The export could not be written."}}}
    func shutdown(){reviewTools.reset();reviewOpenGeneration+=1;cancelReviewImport();saveReview(immediate:true);shuttingDown=true;cancelReviewImport();reviewSaveTask?.cancel();review.cancel();saveTask?.cancel();soundTasks.values.forEach{$0.cancel()};session.prepareShutdown();voice.disconnect();companion.disable();learning.shutdown();audio.stopAll();session.cancelWork();try? store.save(session.state)}
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
