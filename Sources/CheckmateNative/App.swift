import AppKit
import Darwin
import CheckmateCore
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSMenuItemValidation {
    var model:NativeModel?,game:GameWindow?,lockDescriptor:Int32 = -1
    /// The recovery choice and the quit it may lead to; tests answer them without a modal or ending the process.
    var presentRecovery:(NSAlert)->NSApplication.ModalResponse={$0.runModal()},quit:()->Void={NSApp.terminate(nil)}
    /// Silent, with an explicit isolated data directory, and not the released app's identifier.
    static var isolatedAutomation:Bool {NativePolicy.silent && ProcessInfo.processInfo.environment["CHECKMATE_DATA_DIR"] != nil && Bundle.main.bundleIdentifier != "ai.xiaolai.checkmate"}
    func applicationDidFinishLaunching(_ notification:Notification){
        if let i=CommandLine.arguments.firstIndex(of:"--package-check"),i+1<CommandLine.arguments.count {let destination=CommandLine.arguments[i+1];Task{do{let rules=try ChessRules(),course=try CourseLibrary();let analysis=try await NativeEngine().analyze(fen:rules.fen,skill:0,budget:100,multiPv:1);guard let move=analysis.bestMove else{throw CheckmateError.unavailable("No packaged engine move")};_ = try rules.move(uci:move);let result:[String:Any]=["passed":true,"resourceRoot":NativeResources.root.path,"lessons":course.lessons.count,"engineMove":move];try JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:URL(fileURLWithPath:destination));NSApp.terminate(nil)}catch{NSApp.terminate(nil)}};return}
        do {
            let root=StateStore.defaultDirectory();try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // A lock file that cannot be opened is a problem with the data folder, not a second copy: say so.
            let lock=lockInstance(root)
            guard lock != .unopenable else{let alert=NSAlert();alert.messageText="Checkmate could not open its data folder.";alert.informativeText="Check that \(root.path) is writable, then open Checkmate again.";alert.runModal();NSApp.terminate(nil);return}
            guard lock == .held else{for app in NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? ""){if app.processIdentifier != ProcessInfo.processInfo.processIdentifier{app.activate(options:[.activateAllWindows])}};NSApp.terminate(nil);return}
            NativeLog.lifecycle.info("Opening native application");let model=try NativeModel();self.model=model;let window=GameWindow(model:model);game=window;window.board.reviewFiles=reviewFiles;installMenus(window:window,model:model);window.showWindow(nil);NSApp.activate(ignoringOtherApps:true)
            model.startConnections();openPendingFiles()
            // A network game the previous run left behind when it closed (LAN-play plan D9).
            window.offerNetworkCrashReview()
            // Scenario flags mutate and save the game: only an isolated automation run may use them, never the released app.
            let automation=Self.isolatedAutomation
            // A gate may run one instance dark beside light ones (network-ui) without touching the system appearance.
            if automation,CommandLine.arguments.contains("--dark-appearance"){NSApp.appearance=NSAppearance(named:.darkAqua)}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--bonjour-self-check"),i+1<CommandLine.arguments.count{NativeModel.runBonjourSelfCheck(output:URL(fileURLWithPath:CommandLine.arguments[i+1]),directory:root.appendingPathComponent("bonjour-self-check"))}
            if automation,CommandLine.arguments.contains("--companion-test"){try model.companion.enable(role:"coach");if automation,CommandLine.arguments.contains("--preview-fixture"){try model.session.beginPreview();Task{try? await model.session.testMove(from:"e2",to:"e4")}}}
            if automation,CommandLine.arguments.contains("--opponent-fixture"){try model.companion.enable(role:"opponent");try model.session.playWhite(from:"e2",to:"e4")}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--review-batch-scenario"),i+1<CommandLine.arguments.count{runReviewBatchScenario(directory:CommandLine.arguments[i+1])}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--review-scenario"),i+1<CommandLine.arguments.count{runReviewScenario(directory:CommandLine.arguments[i+1])}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--pawn-duel-scenario"),i+1<CommandLine.arguments.count{runPawnDuelScenario(directory:CommandLine.arguments[i+1])}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--snapshot"),i+1<CommandLine.arguments.count{DispatchQueue.main.asyncAfter(deadline:.now()+1){window.snapshot(CommandLine.arguments[i+1])}}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--fullscreen-scenario"),i+1<CommandLine.arguments.count{runFullscreen(directory:CommandLine.arguments[i+1])}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--layout-scenario"),i+1<CommandLine.arguments.count{runLayoutAcceptance(directory:CommandLine.arguments[i+1])}
            if automation,let i=CommandLine.arguments.firstIndex(of:"--ui-scenario"),i+1<CommandLine.arguments.count{runScenario(directory:CommandLine.arguments[i+1])}
        }catch{recoverFromLaunchFailure(error,notification)}
    }
    enum InstanceLock {case held,unopenable,taken}
    /// Opens and locks the data folder's instance lock; a retry after recovery reuses the lock it already holds.
    func lockInstance(_ root:URL)->InstanceLock {guard lockDescriptor<0 else{return .held};lockDescriptor=Darwin.open(root.appendingPathComponent("instance.lock").path,O_CREAT|O_RDWR,0o600);guard lockDescriptor>=0 else{return .unopenable};guard flock(lockDescriptor,LOCK_EX|LOCK_NB)==0 else{Darwin.close(lockDescriptor);lockDescriptor = -1;return .taken};return .held}
    /// The instance lock stays held throughout, so no second copy can start and write the same files meanwhile.
    /// A saved state that cannot be read offers Start Fresh (the file is kept aside), Restore Backup and Export; any
    /// other launch failure says so and quits, so a healthy state is never replaced by an older backup.
    private func recoverFromLaunchFailure(_ error:Error,_ notification:Notification){
        let store=StateStore(directory:StateStore.defaultDirectory()),stateProblem:Bool={do{_ = try store.load();return false}catch{return true}}()
        let alert=NSAlert()
        guard stateProblem else{alert.messageText="Checkmate could not start.";alert.informativeText=userFacingMessage(error,fallback:"A part of the app could not be opened. Reinstall Checkmate if this continues.")+" Your saved progress was not changed.";alert.addButton(withTitle:"Quit");_ = presentRecovery(alert);quit();return}
        alert.messageText="Checkmate could not open your saved progress."
        alert.informativeText=userFacingMessage(error,fallback:"The saved file is damaged or comes from a newer version of Checkmate.")+" Whatever you choose, that file is kept."
        let hasBackup=FileManager.default.fileExists(atPath:store.backupURL.path),choices=["Start Fresh"]+(hasBackup ? ["Restore Backup"]:[])+["Export Saved File…","Quit"]
        for title in choices{alert.addButton(withTitle:title)}
        let index=presentRecovery(alert).rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,original=error
        do{switch choices.indices.contains(index) ? choices[index]:"Quit" {
            case "Start Fresh":try store.setAsideUnreadableState();applicationDidFinishLaunching(notification);return
            case "Restore Backup":try store.restoreBackup();applicationDidFinishLaunching(notification);return
            case "Export Saved File…":let panel=NSSavePanel();panel.nameFieldStringValue="checkmate-saved-state.json";if panel.runModal() == .OK,let url=panel.url{try store.export(to:url)};recoverFromLaunchFailure(error,notification);return
            default:quit();return
        }}catch{let failure=NSAlert();failure.messageText="That did not work";failure.informativeText=userFacingMessage(error,fallback:"Your saved file is unchanged.")+" Choose another option.";failure.runModal();recoverFromLaunchFailure(original,notification)}
    }
    func runReviewBatchScenario(directory:String){guard let model=model else{return};Task{do{
        let root=URL(fileURLWithPath:directory);let warmBaseline=CommandLine.arguments.contains("--warm-engine-baseline");if warmBaseline{_ = try await model.reviewAnalyzer.engine.analyze(fen:try ChessRules().fen,skill:20,budget:100,multiPv:1)};try Data("ready".utf8).write(to:root.appendingPathComponent("baseline-ready"));try await Task.sleep(for:.seconds(2))
        let original=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent("input.pgn")))[0];guard original.mainline.count>=100 else{throw CheckmateError.invalid("Batch fixture requires100real plies")}
        let rules=try ChessRules(fen:original.startingFEN);for node in original.mainline.prefix(100){try rules.move(uci:original.nodes[node].uci!)}
        let document=try PGNImporter.parse(Data(rules.pgn.utf8))[0];model.openReview(document);let analyzer=model.reviewAnalyzer
        let start=Date();analyzer.startBatch(document);var progress:[[String:Any]]=[];var last = -1,lastPhase="",quickPhaseSeconds:Double?=nil
        while ["pending","deepening"].contains(analyzer.batchStatus) && Date().timeIntervalSince(start)<150 {if analyzer.completed>=100,quickPhaseSeconds==nil{quickPhaseSeconds=Date().timeIntervalSince(start)};if analyzer.completed != last || analyzer.batchStatus != lastPhase{last=analyzer.completed;lastPhase=analyzer.batchStatus;progress.append(["completed":last,"phase":lastPhase,"elapsedSeconds":Date().timeIntervalSince(start)])};try await Task.sleep(for:.milliseconds(50))}
        let elapsed=Date().timeIntervalSince(start),completed=analyzer.completed,status=analyzer.batchStatus
        let cancellationDocument=try PGNImporter.parse(Data(("{Cancellation probe} "+document.mainline.map{document.nodes[$0].san!}.joined(separator:" ")+" *").utf8))[0];analyzer.startBatch(cancellationDocument);try await Task.sleep(for:.milliseconds(150));let cancellationWasPending=analyzer.batchStatus=="pending",cancelledProgress=analyzer.completed,cancellationStart=Date();analyzer.cancelBatch();let cancellationMs=Date().timeIntervalSince(cancellationStart)*1000;try await Task.sleep(for:.milliseconds(250))
        // Cancellation must stop the batch it interrupted: no further progress, and the finished part kept as partial.
        let cancellationPassed=cancellationWasPending && analyzer.batchStatus=="partial" && analyzer.completed==cancelledProgress && cancellationMs<500
        let result:[String:Any]=["passed":status=="ready" && completed==100 && elapsed<=90 && cancellationPassed,"cancellationPassed":cancellationPassed,"plies":document.mainline.count,"sourceDocumentHash":original.contentHash,"fixtureHash":document.contentHash,"elapsedSeconds":elapsed,"quickPhaseSeconds":quickPhaseSeconds ?? elapsed,"completed":completed,"status":status,"quickBudgetMs":ReviewPolicy.quickBudget,"progress":progress,"cancellationAcknowledgementMs":cancellationMs,"cancellationStatus":analyzer.batchStatus,"cancellationWasPending":cancellationWasPending,"cancelledProgress":cancelledProgress,"afterCancellationProgress":analyzer.completed,"engineHash":analyzer.engine.binaryIdentity,"engineOptions":AnalysisPolicy.options,"silent":NativePolicy.silent,"calibrationConcurrent":true,"warmEngineBaseline":warmBaseline]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("batch-results.json"));NSApp.terminate(nil)
    }catch{try? JSONSerialization.data(withJSONObject:["passed":false,"error":String(describing:error)]).write(to:URL(fileURLWithPath:directory+"/batch-results.json"));NSApp.terminate(nil)}}}
    func runReviewScenario(directory:String){guard let game=game,let model=model else{return};Task{try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true);var failures:[String]=[],geometry:[[String:Any]]=[]
        do{try await Task.sleep(for:.milliseconds(500));model.session.cancelWork();try model.session.rules.move(uci:"e2e4");model.session.emit(save:true);let practice=model.session.rules.fen,pgn=model.session.state.practice.pgn
            let clipboard=NSPasteboard.general,clipboardItems=clipboard.pasteboardItems?.map{item in item.types.compactMap{type in item.data(forType:type).map{(type,$0)}}} ?? []
            defer {clipboard.clearContents();let items=clipboardItems.map{values in let item=NSPasteboardItem();for (type,data) in values{item.setData(data,forType:type)};return item};clipboard.writeObjects(items)}
            @MainActor func settleImport()async {for _ in 0..<100 {if !model.importingReview{break};try? await Task.sleep(for:.milliseconds(30))};try? await Task.sleep(for:.milliseconds(200))}
            // Out-of-process accessibility checks by Tools/ReviewScenario.swift: what is rendered, not model state.
            var axSequence=0,axLog:[[String:Any]]=[]
            @MainActor func ax(_ name:String,_ checks:[[String:Any]])async -> [[String:Any]] {
                axSequence+=1;let request=URL(fileURLWithPath:directory+"/ax-request-\(axSequence).json"),response=URL(fileURLWithPath:directory+"/ax-result-\(axSequence).json")
                try? FileManager.default.removeItem(at:response);try? JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier,"name":name,"checks":checks]).write(to:request,options:.atomic)
                for _ in 0..<400 {if let data=try? Data(contentsOf:response),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let results=object["results"] as? [[String:Any]]{axLog.append(["name":name,"results":results]);return results};try? await Task.sleep(for:.milliseconds(100))}
                axLog.append(["name":name,"results":"no helper response"]);return []
            }
            func axPassed(_ results:[[String:Any]],_ index:Int)->Bool {results.indices.contains(index) && results[index]["passed"] as? Bool==true}
            clipboard.clearContents();clipboard.setString("[Event \"Pasted entry\"]\n1. e4 *",forType:.string);pasteReview();await settleImport()
            let pastePassed=model.review.document?.title.contains("Pasted entry")==true
            if !pastePassed{failures.append("Paste menu/model import failed")}
            let beforeInvalid=model.review.document?.contentHash;clipboard.clearContents();clipboard.setString("1. e9 *",forType:.string);pasteReview();await settleImport()
            if model.review.document?.contentHash != beforeInvalid || model.storageError==nil{failures.append("Invalid paste replaced current review")}
            let invalidMessage=model.storageError ?? ""
            let readableError=invalidMessage.hasPrefix("Record 1, token") && invalidMessage.contains("e9") && !invalidMessage.contains("ReviewImportError")
            if !readableError{failures.append("Import error is not a located readable message: \(invalidMessage)")}
            try? await Task.sleep(for:.milliseconds(400));try? await game.capture(directory+"/error-banner.png")
            let errorAX=await ax("rendered-import-error",[["kind":"text","value":invalidMessage],["kind":"press","title":"Dismiss"]])
            try? await Task.sleep(for:.milliseconds(400))
            let renderedErrorPassed=axPassed(errorAX,0) && axPassed(errorAX,1) && model.storageError==nil && game.errorBanner?.isHidden==true
            if !renderedErrorPassed{failures.append("Import error was not rendered/dismissed in the window")}
            var openPanelCancelled=false
            let openTimer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){timer in
                if let panel=NSApp.windows.compactMap({$0 as? NSOpenPanel}).first {openPanelCancelled=true;panel.cancel(nil);timer.invalidate()}
            }
            RunLoop.main.add(openTimer,forMode:.common);RunLoop.main.add(openTimer,forMode:.modalPanel)
            openPGN();try await Task.sleep(for:.milliseconds(500));openTimer.invalidate()
            if !openPanelCancelled || model.review.document?.contentHash != beforeInvalid{failures.append("Open panel cancellation changed review or was not exercised")}
            let file=URL(fileURLWithPath:directory+"/entry-file.pgn");try Data("[Event \"File callback entry\"]\n1. d4 *".utf8).write(to:file)
            let openDirectory=URL(fileURLWithPath:directory+"/open-panel-fixture");try FileManager.default.createDirectory(at:openDirectory,withIntermediateDirectories:true)
            let panelFile=openDirectory.appendingPathComponent("accepted.pgn");try Data("[Event \"Accepted Open panel\"]\n1. Nf3 *".utf8).write(to:panelFile)
            var openTicks=0
            let acceptTimer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){timer in
                guard let panel=NSApp.windows.compactMap({$0 as? NSOpenPanel}).first else{return};openTicks+=1
                // A liveness bound: the helper types the fixture's path into Go to Folder, which takes a few seconds.
                if openTicks>100{panel.cancel(nil);timer.invalidate()}
            }
            RunLoop.main.add(acceptTimer,forMode:.common);RunLoop.main.add(acceptTimer,forMode:.modalPanel);model.openPGN(startingIn:openDirectory);try JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier,"path":panelFile.path]).write(to:URL(fileURLWithPath:directory+"/open-panel-ready.json"));try await Task.sleep(for:.seconds(8));acceptTimer.invalidate();await settleImport()
            FileHandle.standardError.write(Data("Open accepted attempts \(openTicks)\n".utf8))
            let openPanelAccepted=model.review.document?.title.contains("Accepted Open panel")==true
            FileHandle.standardError.write(Data("Panel import title \(model.review.document?.title ?? "nil") error \(model.storageError ?? "nil")\n".utf8))
            if !openPanelAccepted{failures.append("Open panel accepted-file path failed")}
            game.board.dropReview?(try Data(contentsOf:file));await settleImport()
            let dropCallbackPassed=model.review.document?.title.contains("File callback entry")==true
            if !dropCallbackPassed{failures.append("Board drop callback import failed")}
            // Exercise the actual chooser and choose its second item, without UI scraping.
            let collection="[Event \"First collection item\"]\n1. e4 *\n\n[Event \"Second collection item\"]\n1. d4 *"
            var chooserHandled=false,chooserTicks=0
            let chooserTimer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){timer in
                chooserTicks+=1
                if chooserTicks>40{NSApp.stopModal(withCode:.alertSecondButtonReturn);timer.invalidate()}
                guard let window=NSApp.modalWindow else{return}
                FileHandle.standardError.write(Data("Chooser tick \(chooserTicks) window \(window.title)\n".utf8))
                func picker(_ view:NSView)->NSPopUpButton? {if let found=view as? NSPopUpButton{return found};for child in view.subviews{if let found=picker(child){return found}};return nil}
                if let root=window.contentView,let selection=picker(root),selection.numberOfItems==2{selection.selectItem(at:1);chooserHandled=true;NSApp.stopModal(withCode:.alertFirstButtonReturn);timer.invalidate()}
            }
            RunLoop.main.add(chooserTimer,forMode:.common);RunLoop.main.add(chooserTimer,forMode:.modalPanel)
            FileHandle.standardError.write(Data("Starting collection\n".utf8))
            model.importReviewData(Data(collection.utf8));await settleImport();chooserTimer.invalidate()
            let collectionPassed=chooserHandled && model.review.document?.title.contains("Second collection item")==true
            if !collectionPassed{failures.append("Collection chooser second item failed")}
            // A newer activity (here another opened record) during the chooser's modal loop wins over the later choice.
            let duringChooserRecord=Data("[Event \"Opened during chooser\"]\n1. c4 *".utf8);var staleChooserHandled=false,staleTicks=0
            let staleTimer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){timer in
                staleTicks+=1;if staleTicks>40{NSApp.stopModal(withCode:.alertSecondButtonReturn);timer.invalidate()}
                guard let window=NSApp.modalWindow else{return}
                func picker(_ view:NSView)->NSPopUpButton? {if let found=view as? NSPopUpButton{return found};for child in view.subviews{if let found=picker(child){return found}};return nil}
                if let root=window.contentView,let selection=picker(root),selection.numberOfItems==2{selection.selectItem(at:1);MainActor.assumeIsolated{if let record=try? PGNImporter.parse(duringChooserRecord).first{model.openReview(record)}};staleChooserHandled=true;NSApp.stopModal(withCode:.alertFirstButtonReturn);timer.invalidate()}
            }
            RunLoop.main.add(staleTimer,forMode:.common);RunLoop.main.add(staleTimer,forMode:.modalPanel)
            model.importReviewData(Data("[Event \"Third collection item\"]\n1. e4 *\n\n[Event \"Fourth collection item\"]\n1. d4 *".utf8));await settleImport();staleTimer.invalidate()
            let staleChooserPassed=staleChooserHandled && model.review.document?.header("Event")=="Opened during chooser"
            if !staleChooserPassed{failures.append("Chooser choice replaced an activity selected during its modal loop")}
            let chooserRecord=model.review.document!
            model.returnToGame();let resumedOnExplicitReturn=model.session.busyReason=="opponent";model.session.cancelWork();game.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            if !resumedOnExplicitReturn{failures.append("Explicit Return to game did not resume the suspended opponent reply")}
            // Returning queued a save of the record; an unsaved in-memory review reopens as it was left (its newer state wins
            // over any file), so the injected restore below is exercised only once that save has landed.
            for _ in 0..<150 where model.reviewSavePending(chooserRecord.id) {try? await Task.sleep(for:.milliseconds(20))}
            if model.reviewSavePending(chooserRecord.id){failures.append("The returned review's save never landed")}
            // M9: an invalid saved cursor injected through openReview's restore path while practice is Black-to-move.
            // The failure must not start the opponent or change practice/owner; the rendered error names the explicit
            // action. The session gate also refuses every callback reply entry (voice hold/close, connection, settings);
            // after Dismiss with both drawers closed, the bottom transport's Resume game (out-of-process AX) resumes it.
            var invalidSaved=try model.reviewStore.load(chooserRecord.id);invalidSaved.cursor=chooserRecord.nodes.count+7
            let failPGN=model.session.state.practice.pgn,failHistory=model.session.rules.history.count,failMode=model.session.mode
            let blackToMove=model.session.rules.turn=="b" && model.session.opponentSide=="b" && !model.session.busy && !model.session.rules.over
            model.openReview(chooserRecord,saved:invalidSaved)
            let failureMessage=model.storageError ?? ""
            let quietAtFailure = !model.session.busy && !model.review.active && !model.session.reviewSuspended && model.session.mode==failMode && model.session.lesson==nil && model.restoreResumePending
            try await Task.sleep(for:.milliseconds(700))
            let stillQuiet = !model.session.busy && model.session.rules.history.count==failHistory && model.session.state.practice.pgn==failPGN && model.session.mode==failMode
            // Callback entry points that previously restarted the computer.
            let heldSettings=model.session.state.settings,heldRole=model.session.companionRole
            model.session.holdVoice(true);model.session.holdVoice(false);model.session.closeVoice()
            model.session.setConnection(enabled:true,role:heldRole);model.session.setConnection(enabled:false,role:heldRole)
            var changedPreset=heldSettings;changedPreset.opponentPreset=heldSettings.opponentPreset=="club" ? "gentle":"club";model.session.updateSettings(changedPreset)
            try await Task.sleep(for:.milliseconds(700))
            let callbacksHeld = !model.session.busy && model.session.rules.history.count==failHistory && model.restoreResumePending
            model.session.updateSettings(heldSettings)
            if model.session.busy || !model.restoreResumePending{failures.append("Restoring opponent settings resumed the held reply")}
            game.refresh();try? await game.capture(directory+"/restore-failure-paused.png")
            // Dismiss alone never resumes.
            let restoreAX=await ax("restore-failure-paused",[["kind":"text","value":failureMessage],["kind":"enabled","title":"Return to game","expected":true],["kind":"press","title":"Dismiss"]])
            try await Task.sleep(for:.milliseconds(700))
            let quietAfterDismiss = !model.session.busy && model.session.rules.history.count==failHistory && model.storageError==nil && game.errorBanner?.isHidden==true
            // The practice pane heading reflects the pause ("Game paused" replaces the game-state heading) and keeps its own Return to game.
            let leftWasOpen=game.desiredLeft,rightWasOpen=game.desiredRight;game.showDetails();game.refresh();try await Task.sleep(for:.milliseconds(900));try? await game.capture(directory+"/restore-failure-details.png")
            let detailsAX=await ax("restore-failure-details",[["kind":"text","value":"Game paused"],["kind":"text","value":"Your game is paused because a saved review could not be restored."],["kind":"enabled","title":"Return to game","expected":true]])
            // Both drawers closed: recovery needs no drawer; the bottom transport's Resume game is pressed out of process.
            if game.desiredLeft{game.toggleLeft()};if game.desiredRight{game.toggleRight()};try await Task.sleep(for:.milliseconds(900));game.refresh();try? await game.capture(directory+"/restore-failure-drawers-closed.png")
            let drawersClosed = !game.desiredLeft && !game.desiredRight
            let quietBeforeResume = !model.session.busy && model.session.rules.history.count==failHistory
            let resumeAX=await ax("restore-failure-resume-closed-drawers",[["kind":"enabled","title":"Resume game","expected":true],["kind":"press","title":"Resume game"]])
            var resumedByExplicitAction=false
            for _ in 0..<50 {if model.session.busyReason=="opponent" || model.session.rules.history.count>failHistory{resumedByExplicitAction=true;break};try? await Task.sleep(for:.milliseconds(20))}
            let resumeCleared = !model.restoreResumePending
            model.session.cancelWork();if model.session.rules.history.count != failHistory{try model.session.rules.restore(failPGN);model.session.emit(save:true)}
            // A deliberate replacement (New game) clears the obsolete hold and its paused sentence.
            let savedState=model.session.state
            model.openReview(chooserRecord,saved:invalidSaved);let heldAgain=model.restoreResumePending && model.storageError==NativeModel.failedRestorePausedMessage
            model.session.newGame();try await Task.sleep(for:.milliseconds(400))
            let replacementCleared=heldAgain && !model.restoreResumePending && model.storageError==NativeModel.failedRestoreMessage && !model.session.busy
            // Return to the held game through the session's own restore path (New game kept it as the previous game).
            model.dismissStorageError();try model.session.restorePrevious();model.session.cancelWork();model.session.state=savedState;model.session.emit(save:true)
            if model.session.state.practice.pgn != failPGN{failures.append("Scenario could not restore the practice game after the replacement check")}
            if leftWasOpen{game.toggleLeft()};if rightWasOpen{game.toggleRight()};try? await Task.sleep(for:.milliseconds(900))
            let failedRestorePassed=blackToMove && quietAtFailure && stillQuiet && callbacksHeld && quietAfterDismiss && failureMessage.contains("Return to game") && axPassed(restoreAX,0) && axPassed(restoreAX,1) && axPassed(restoreAX,2) && (0..<3).allSatisfy{axPassed(detailsAX,$0)} && drawersClosed && quietBeforeResume && axPassed(resumeAX,0) && axPassed(resumeAX,1) && resumedByExplicitAction && resumeCleared && replacementCleared && model.storageError==nil && game.errorBanner?.isHidden==true && model.session.mode == .practice && model.session.state.practice.pgn==failPGN
            if !failedRestorePassed{failures.append("Failed saved-review restore started the opponent or lacked a rendered explicit resume (blackToMove=\(blackToMove) quiet=\(quietAtFailure) stillQuiet=\(stillQuiet) callbacksHeld=\(callbacksHeld) afterDismiss=\(quietAfterDismiss) drawersClosed=\(drawersClosed) resumed=\(resumedByExplicitAction) cleared=\(resumeCleared) replacement=\(replacementCleared) message=\(failureMessage))")}
            let docs=try PGNImporter.parse(Data("[Event \"Automation record\"]\n1. d4 d5 (1... Nf6) 2. c4 e6 *".utf8));model.openReview(docs[0]);try await Task.sleep(for:.milliseconds(850));game.refresh();let originalHash=model.review.document!.contentHash,boardWidth=game.board.boardRect.width
            let noReplyDuringReview = !model.session.busy && model.session.rules.history.count==1
            if !noReplyDuringReview{failures.append("Opponent reply scheduled while review is open")}
            for (name,action) in [("overview",{}),("both",{game.toggleLeft()}),("closed-right",{game.toggleRight()}),("right-restored",{game.toggleRight()})]{action();try await Task.sleep(for:.milliseconds(850));game.refresh();geometry.append(["phase":name,"boardWidth":game.board.boardRect.width,"windowWidth":game.window!.frame.width]);if abs(game.board.boardRect.width-boardWidth)>1{failures.append("Review changed square board dimensions")};try? await game.capture(directory+"/"+name+".png")}
            var appearances:[String]=[]
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua),("contrast-light",.accessibilityHighContrastAqua),("contrast-dark",.accessibilityHighContrastDarkAqua)] {
                game.window?.appearance=NSAppearance(named:appearance);game.board.automationIncreaseContrast=name.hasPrefix("contrast");game.refresh();try await Task.sleep(for:.milliseconds(150));try? await game.capture(directory+"/appearance-"+name+".png");appearances.append(name)
                if abs(game.board.boardRect.width-boardWidth)>1{failures.append("Appearance changed board dimensions")}
            }
            game.window?.appearance=nil;game.board.automationIncreaseContrast=nil
            let defaultMotion=game.board.shouldReduceMotion==NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !defaultMotion{failures.append("Default motion preference differs from workspace")}
            game.board.automationReduceMotion=true;game.board.selected="e2";game.board.updateBreathing()
            if game.board.breathing{failures.append("Reduced Motion override retained breathing")}
            // An animation only runs on the board it belongs to: show the start position the move is played from.
            game.board.position=try ChessRules().board;let move=try ChessRules().moves("e2").first!;game.board.animate(move,duration:1)
            if game.board.moveAnimationActive{failures.append("Reduced Motion override retained move animation")}
            game.board.automationReduceMotion=false;game.board.animate(move,duration:1)
            if !game.board.moveAnimationActive{failures.append("Normal motion override did not start animation")};game.board.cancelAnimation()
            game.board.automationReduceMotion=nil;game.board.selected=nil;game.board.updateBreathing();game.refresh()
            let accessibleSquares=game.board.accessibilityChildren()?.compactMap{$0 as? NSAccessibilityElement} ?? []
            if accessibleSquares.count != 64 || game.board.accessibilityLabel() != "Chessboard"{failures.append("Board accessibility tree incomplete")}
            game.window?.makeFirstResponder(game.board)
            @MainActor func key(_ code:UInt16){if let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:game.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code){NSApp.sendEvent(event)}}
            model.session.setVoiceFocus(["h4"],identity:model.session.displayIdentity);game.refresh();if !game.board.highlights.contains(where:{$0.sq=="h4" && $0.kind=="focus"}){failures.append("Verified review speech focus was not rendered")};model.session.setVoiceFocus([],identity:model.session.displayIdentity)
            model.review.annotate(arrows:[["e2","e4"]],highlights:[Highlight(sq:"e4",kind:"focus")],ttl:5000);game.refresh();let annotationRendered=game.board.arrows.contains(["e2","e4"]) && game.board.highlights.contains(where:{$0.sq=="e4" && $0.kind=="focus"});if !annotationRendered{failures.append("Scoped review annotation was not rendered")}
            key(124);let annotationCleared=model.review.arrows.isEmpty && model.review.highlights.isEmpty;if !annotationCleared{failures.append("Review annotation survived navigation")};let rightArrowVerified=model.review.nodeID==docs[0].mainline.first;if !rightArrowVerified{failures.append("Right arrow failed review navigation")};key(123);let leftArrowVerified=model.review.nodeID==0;if !leftArrowVerified{failures.append("Left arrow failed review navigation")}
            let typing=NSTextField(string:"Review search text");typing.frame=NSRect(x:0,y:0,width:180,height:24);game.window!.contentView!.addSubview(typing);game.window!.makeFirstResponder(typing);key(124);let typingPreserved=model.review.nodeID==0;if !typingPreserved{failures.append("Review captured text-field arrow typing")};typing.removeFromSuperview();game.window!.makeFirstResponder(game.board)
            game.newGame();game.undo();game.restorePrevious();let menuGuardPassed=model.session.rules.fen==practice;if !menuGuardPassed{failures.append("Game menu action mutated hidden practice during review")}
            // Review voice status and newest-first transcript are rendered in the review drawer (no network, no audio).
            game.showDetails();model.voice.receive(["type":"session.updated"])
            model.voice.receive(["type":"response.output_audio_transcript.done","response_id":"review-older","transcript":"Older review explanation."])
            model.voice.receive(["type":"response.output_audio_transcript.done","response_id":"review-newer","transcript":"Newest review explanation."])
            model.voice.receive(["type":"response.done","response":["status":"failed"]])
            let voiceStatus=model.voice.status;try? await Task.sleep(for:.milliseconds(900));try? await game.capture(directory+"/review-voice.png")
            let voiceAX=await ax("review-voice",[["kind":"text","value":voiceStatus],["kind":"text","value":"Newest review explanation."],["kind":"text","value":"Older review explanation."],["kind":"textOrder","values":["Newest review explanation.","Older review explanation."]]])
            let reviewVoicePassed=voiceStatus=="The coach could not complete this response." && (0..<4).allSatisfy{axPassed(voiceAX,$0)} && model.voice.history.last?.context=="Review · starting position" && !model.session.voiceHold
            if !reviewVoicePassed{failures.append("Review voice status/newest-first transcript not rendered")}
            // A failed turn keeps the session; this simulated one ends here so the rest of the review runs without voice.
            model.voice.disconnect()

            try model.review.beginBranch();game.refresh()
            @MainActor func click(_ square:String)async {let rect=game.board.squareRect(square),point=game.board.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil);for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp]{if let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:game.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1:0){NSApp.sendEvent(event)};try? await Task.sleep(for:.milliseconds(80))}}
            await click("e2");await click("e4");let mouseBranchVerified=model.review.board["e4"]=="wp";if !mouseBranchVerified{failures.append("Actual mouse branch move failed")};try? await game.capture(directory+"/imagined-mouse.png");key(126);key(126);key(126);key(49);key(125);key(125);key(49);let keyboardBranchVerified=model.review.board["e5"]=="bp" && model.review.branch?.moves.count==2;if !keyboardBranchVerified{failures.append("Actual keyboard imagined move failed")};try? await game.capture(directory+"/imagined-keyboard.png");game.showDetails();game.refresh();try? await Task.sleep(for:.milliseconds(700))
            // RV-2: the open idea lists its own moves, rendered and read from outside the app.
            let ideaMovesAX=await ax("idea-moves",[["kind":"text","value":"Imagined move 1, e4"],["kind":"text","value":"Imagined move 2, e5"]]);let ideaMovesListed=axPassed(ideaMovesAX,0) && axPassed(ideaMovesAX,1);if !ideaMovesListed{failures.append("The open idea does not list its moves")}
            model.review.clearBranch();if model.review.nodeID != 0 || model.review.document!.contentHash != originalHash{failures.append("Branch changed original cursor/hash")}
            if model.session.rules.fen != practice || model.session.state.practice.pgn != pgn{failures.append("Review modified suspended practice")}
            try model.review.select(docs[0].mainline.last!);model.saveReview();try? await game.capture(directory+"/last-position.png")
            model.saveReview(immediate:true);let savedCursor=model.review.nodeID,savedIdeas=model.review.branchesForSaving
            model.returnToGame();model.session.cancelWork();model.openSavedReview(docs[0].id);try await Task.sleep(for:.milliseconds(500))
            let savedRestorePassed=model.review.nodeID==savedCursor && model.review.branchesForSaving==savedIdeas
            if !savedRestorePassed{failures.append("Saved cursor/ideas overwritten during library restoration")}
            try model.review.select(0);model.returnToGame();model.session.cancelWork()
            let closeFlushPassed=try ReviewStore(directory:model.reviewStore.directory).load(docs[0].id).cursor==0
            if !closeFlushPassed{failures.append("Close before debounce lost latest cursor")}
            model.automationReviewLoadDelayMs=400;model.openSavedReview(docs[0].id);model.lesson(0)
            try await Task.sleep(for:.milliseconds(650))
            let savedLoadLessonPassed = !model.review.active && model.session.mode == .lesson
            if !savedLoadLessonPassed{failures.append("Stale saved load replaced a newer lesson")}
            model.practice();model.session.cancelWork()
            model.openSavedReview(docs[0].id);model.importReviewData(Data("[Event \"Latest import\"]\n1. e4 *".utf8))
            try await Task.sleep(for:.milliseconds(650))
            let savedLoadImportPassed=model.review.document?.header("Event")=="Latest import"
            if !savedLoadImportPassed{failures.append("Stale saved load replaced a direct import")}
            let latestDocument=model.review.document!;model.saveCurrentReview();model.returnToGame();model.session.cancelWork()
            model.openSavedReview(docs[0].id);model.automationReviewLoadDelayMs=0;model.openSavedReview(latestDocument.id)
            try await Task.sleep(for:.milliseconds(650))
            let savedLoadLatestPassed=model.review.document?.id==latestDocument.id
            if !savedLoadLatestPassed{failures.append("Older saved load replaced the latest saved request")}
            model.automationReviewLoadDelayMs=400;model.openSavedReview(docs[0].id);model.openSavedReview(latestDocument.id)
            try await Task.sleep(for:.milliseconds(650))
            let savedLoadSameIDPassed=model.review.document?.id==latestDocument.id
            if !savedLoadSameIDPassed{failures.append("Same-ID request did not invalidate an older load")}
            model.openSavedReview(UUID());model.openReview(latestDocument);model.storageError=nil
            try await Task.sleep(for:.milliseconds(650))
            let savedLoadErrorPassed=model.storageError==nil
            if !savedLoadErrorPassed{failures.append("Stale saved-load error reached a newer activity")}
            model.automationReviewLoadDelayMs=0;model.automationReviewImportDelayMs=400
            model.importReviewData(Data("1. e4 *".utf8));model.returnToGame();model.session.cancelWork()
            try await Task.sleep(for:.milliseconds(650))
            let staleImportPassed = !model.review.active && !model.importingReview
            if !staleImportPassed{failures.append("Stale import replaced a newer return-to-game activity")}
            model.automationReviewImportDelayMs=0
            model.openSavedReview(docs[0].id);for _ in 0..<40{if model.review.document?.id==docs[0].id{break};try await Task.sleep(for:.milliseconds(100))};try model.review.select(docs[0].mainline.last!);model.saveReview(immediate:true);game.refresh()
            if !game.desiredLeft{game.toggleLeft()};try? await Task.sleep(for:.milliseconds(900))
            let selectionAX=await ax("saved-review-selected",[["kind":"selectedRow","value":"Automation record"]]);let savedRowSelected=axPassed(selectionAX,0)
            if !savedRowSelected{failures.append("Open saved review is not selected in the sidebar")}
            game.window?.toggleFullScreen(nil);try await Task.sleep(for:.seconds(2));let entered=game.window!.styleMask.contains(.fullScreen);if !entered{failures.append("Review fullscreen failed")};try? await game.capture(directory+"/fullscreen-review.png");game.window?.toggleFullScreen(nil);try await Task.sleep(for:.seconds(2))
            model.session.cancelWork();model.returnToGame();model.session.cancelWork();if model.session.rules.fen != practice{failures.append("Return to game changed practice position")}
            let preservedPractice=model.session.rules.fen==practice;try model.session.installPracticeFork(model.session.rules.copy(),side:"b");model.session.cancelWork();game.refresh();let blackPracticeTitle=game.titleView.label.stringValue;if !blackPracticeTitle.contains("Black vs"){failures.append("Black practice fork title states wrong human side")}
            // "Compare best line · before this move" then the real confirmation sheet: the fork is the displayed
            // parent-rooted imagined position, at ply 0 and ply 1; checkmate positions keep Practise here disabled.
            let mateDocument=try PGNImporter.parse(Data("[Event \"Fork from parent\"]\n1. f3 e5 2. g4 Qh4# 0-1".utf8))[0],mateNode=mateDocument.mainline.last!,bestLine=["b8c6","b1c3","d8h4"]
            game.showDetails()
            @MainActor func compareFromParent(_ ply:Int)async throws {model.openReview(mateDocument);try model.review.select(mateNode);try model.review.previewLine(bestLine,fromNode:model.review.document!.nodes[model.review.nodeID].parent);model.review.seekBranch(0);if ply>0{model.review.seekBranch(ply)};game.refresh();try await Task.sleep(for:.milliseconds(900))}
            model.openReview(mateDocument);try model.review.select(mateNode);try await Task.sleep(for:.milliseconds(900))
            let mateDisabledAX=await ax("practise-disabled-at-mate",[["kind":"enabled","title":"Practise here","expected":false]])
            try await compareFromParent(0);let parentFEN=model.review.displayFEN
            let parentEnabledAX=await ax("practise-enabled-parent-ply0",[["kind":"enabled","title":"Practise here","expected":true],["kind":"press","title":"Practise here"]])
            try await Task.sleep(for:.milliseconds(900));try? await game.capture(directory+"/practice-fork-sheet.png")
            let sheetPly0AX=await ax("confirm-fork-ply0",[["kind":"press","title":"Start practice"]]);try await Task.sleep(for:.milliseconds(600))
            let ply0Records=model.session.rules.records
            let forkPly0Verified=axPassed(mateDisabledAX,0) && axPassed(parentEnabledAX,0) && axPassed(parentEnabledAX,1) && axPassed(sheetPly0AX,0) && !model.review.active && !model.practiceForkRequested && ply0Records.count>=3 && ply0Records.prefix(3).map(\.san)==["f3","e5","g4"] && ply0Records[2].after==parentFEN && model.storageError==nil
            if !forkPly0Verified{failures.append("Confirmation-sheet fork at imagined parent ply 0 used the wrong position")}
            model.session.cancelWork()
            try await compareFromParent(1);let plyOneFEN=model.review.displayFEN
            let plyOneAX=await ax("confirm-fork-ply1",[["kind":"press","title":"Practise here"]]);try await Task.sleep(for:.milliseconds(900))
            let sheetPly1AX=await ax("confirm-fork-ply1-sheet",[["kind":"press","title":"Start practice"]]);try await Task.sleep(for:.milliseconds(600))
            let ply1Records=model.session.rules.records
            let forkPly1Verified=axPassed(plyOneAX,0) && axPassed(sheetPly1AX,0) && !model.review.active && ply1Records.count>=4 && ply1Records.prefix(4).map(\.san)==["f3","e5","g4","Nc6"] && ply1Records[3].after==plyOneFEN && model.storageError==nil
            if !forkPly1Verified{failures.append("Confirmation-sheet fork at imagined parent ply 1 used the wrong position")}
            model.session.cancelWork()
            try await compareFromParent(3);let terminalAX=await ax("practise-disabled-imagined-mate",[["kind":"enabled","title":"Practise here","expected":false]])
            let terminalLineVerified=axPassed(terminalAX,0) && model.review.displayRules?.checkmate==true
            if !terminalLineVerified{failures.append("Imagined checkmate left Practise here enabled")}
            model.returnToGame();model.session.cancelWork()
            // The review pane in light and dark: the workspace and its game library (all, a search, the World
            // Championships grouped by event, My games, a narrow window), then a fixed short library game's overview,
            // a mid-game position with the evaluation graph, and an imagined line there.
            var paneCaptures:[String]=[]
            var captureDefects:[String]=[],paneSizes:[String:String]=[:]
            // A capture counts only if it is the window alone: its pixel size is the window's at the display's scale, and
            // the window fills it (opaque samples across the whole image, not one corner of a larger canvas).
            @MainActor func capturedWindow(_ path:String,_ name:String)->Bool {
                guard let window=game.window,let image=NSImage(contentsOfFile:path),let rep=image.representations.first as? NSBitmapImageRep else{captureDefects.append(name+": unreadable");return false}
                let scale=window.backingScaleFactor,expected=(Int((window.frame.width*scale).rounded()),Int((window.frame.height*scale).rounded()))
                paneSizes[name]="\(rep.pixelsWide)x\(rep.pixelsHigh)"
                guard abs(rep.pixelsWide-expected.0)<=2,abs(rep.pixelsHigh-expected.1)<=2 else{captureDefects.append(name+": \(rep.pixelsWide)x\(rep.pixelsHigh), window \(expected.0)x\(expected.1)");return false}
                var opaque=0,samples=0
                for x in stride(from:0.05,through:0.95,by:0.1){for y in stride(from:0.05,through:0.95,by:0.1){samples+=1;if (rep.colorAt(x:Int(Double(rep.pixelsWide)*x),y:Int(Double(rep.pixelsHigh)*y))?.alphaComponent ?? 0)>0.9{opaque+=1}}}
                guard opaque==samples else{captureDefects.append(name+": window covers \(opaque) of \(samples) samples");return false}
                return true
            }
            @MainActor func shoot(_ name:String)async {for (suffix,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)]{game.window?.appearance=NSAppearance(named:appearance);game.refresh();try? await Task.sleep(for:.milliseconds(500));let path=directory+"/pane-\(name)-\(suffix).png";if (try? await game.capture(path)) != nil,capturedWindow(path,name+"-"+suffix){paneCaptures.append(name+"-"+suffix)}};game.window?.appearance=nil}
            let library=model.library
            // Plan WI-16 budgets on the visible path, with 165 bundled and 5,000 imported rows: the clock stops only when the
            // expected row exists in the window's accessibility tree (SwiftUI builds it only for rows it has laid out).
            let timingRecords=(0..<5000).map{i in "[Event \"Club \(i % 40)\"]\n[White \"Player\(i)\"]\n[Black \"Rival\(i % 300)\"]\n[Result \"1-0\"]\n\n1. e4 e5 1-0\n"}.joined(separator:"\n")
            let timingCollection=try library.store.importCollection(Data(timingRecords.utf8),name:"timing.pgn")
            @MainActor func rowVisible(_ id:String)->Bool {
                func find(_ element:Any,_ depth:Int)->Bool {
                    guard depth<60,let node=element as? NSObject else{return false}
                    func call(_ name:String)->Any? {let selector=NSSelectorFromString(name);return node.responds(to:selector) ? node.perform(selector)?.takeUnretainedValue():nil}
                    if call("accessibilityIdentifier") as? String=="library-row-"+id{return true}
                    // Table rows are reached through the view tree (only laid-out row views exist) and SwiftUI's accessibility
                    // children; the table's `accessibilityRows` would build an element for every row and is not walked.
                    let children:[Any]=((node as? NSView)?.subviews ?? [])+(call("accessibilityChildren") as? [Any] ?? [])
                    return children.contains{find($0,depth+1)}
                }
                return game.window?.contentView.map{find($0,0)} ?? false
            }
            // Done only when the new first result is on screen and the old results it replaces are gone: a row the previous
            // query also showed would otherwise count as the new result before the list has changed.
            // The list's own table: its row count is what the screen draws (a header row per section plus its game rows).
            @MainActor func tables(_ view:NSView?)->[NSTableView] {guard let view else{return []};return (view as? NSTableView).map{[$0]} ?? view.subviews.flatMap{tables($0)}}
            @MainActor func table(_ view:NSView?)->NSTableView? {
                tables(view).first{t in var v:NSView?=t;while let current=v{if current.accessibilityIdentifier()=="library-list"{return true};v=current.superview};return false}
                    // Before SwiftUI has named its views the list is the table holding exactly the expected rows.
                    ?? tables(view).first{$0.numberOfRows==library.items.count}
            }
            var tableCounts:[String]=[],phase:[(Date,Date)]=[],phases:[String]=[]
            // The clock stops only when the table has applied this exact version of the lines, in this exact order (a row
            // count can match before the table has changed), and has then drawn them.
            @MainActor func waitTable(_ query:String)async -> Bool {
                let expected=library.items.map(\.id),version=library.shownVersion
                for _ in 0..<1000{if let t=table(game.window?.contentView) as? LibraryTableView,t.appliedVersion==version,t.appliedIDs==expected,t.numberOfRows==expected.count{let counted=Date();t.displayIfNeeded();phase.append((counted,Date()));return true};try? await Task.sleep(for:.milliseconds(1))}
                tableCounts.append("\(query): table \(table(game.window?.contentView)?.numberOfRows ?? -1), all \(tables(game.window?.contentView).map{"\(type(of:$0)):\($0.numberOfRows):\($0.accessibilityIdentifier())"}), expected \(expected)");return false
            }
            @MainActor func waitVisible(_ id:String?,gone:[String]=[])async -> Bool {guard let id else{return false};for _ in 0..<1000{if rowVisible(id),!gone.contains(where:rowVisible){return true};try? await Task.sleep(for:.milliseconds(2))};return false}
            let shownAt=Date();model.showReviewWorkspace();library.reload()
            for _ in 0..<1000{if library.loaded,library.catalog.rowCount>=5165{break};try await Task.sleep(for:.milliseconds(2))}
            let tableShown=await waitTable("")
            let workspaceVisibleMs=Int(Date().timeIntervalSince(shownAt)*1000),timedRows=library.catalog.rowCount
            let firstShown=await waitVisible(library.catalog.sections(scope:library.scope,query:"").first?.rows.first?.id) && tableShown
            var previous=Array(library.catalog.sections(scope:library.scope,query:"").flatMap(\.rows).prefix(3).map(\.id))
            var slowestKeystrokeMs=0,keystrokesShown=firstShown,keystrokeMs:[String:Int]=[:]
            for query in ["k","ka","kar","karp","karpo","karpov","c","ca","car","carl","t","ta","tal"]{
                // The expected results are worked out before the clock starts: only the app's own work is timed.
                let rows=library.catalog.sections(scope:library.scope,query:query).flatMap(\.rows).map(\.id),kept=Set(rows)
                let typed=Date();library.query=query;let filtered=Date()
                // The clock stops when the list's table holds exactly the new results and has drawn them. Walking the
                // accessibility tree afterwards (outside the clock: it makes SwiftUI build an element for each new row,
                // ~800 ms that no sighted user waits for) confirms the right rows are the ones shown.
                let applied=await waitTable(query)
                if let last=phase.last,let t=table(game.window?.contentView) as? LibraryTableView{phases.append("\(query): filter \(Int(filtered.timeIntervalSince(typed)*1000)), apply \(Int(t.applyStarted.timeIntervalSince(typed)*1000))-\(Int(t.applyFinished.timeIntervalSince(typed)*1000)), table \(Int(last.0.timeIntervalSince(typed)*1000)), drawn \(Int(last.1.timeIntervalSince(typed)*1000))")}
                let elapsed=Int(Date().timeIntervalSince(typed)*1000);keystrokeMs[String(keystrokeMs.count)+":"+query]=elapsed;slowestKeystrokeMs=max(slowestKeystrokeMs,elapsed)
                let shown=await waitVisible(rows.first,gone:previous.filter{!kept.contains($0)});keystrokesShown=keystrokesShown && shown && applied;previous=Array(rows.prefix(3))
            }
            library.query=""
            library.remove(timingCollection.sha256);for _ in 0..<200{if library.collection(timingCollection.sha256)==nil,library.catalog.collections.isEmpty{break};try await Task.sleep(for:.milliseconds(20))}
            let budgetsPassed=timedRows>=5165 && keystrokesShown && workspaceVisibleMs<300 && slowestKeystrokeMs<50
            if !budgetsPassed{failures.append("Library budgets missed (rows \(timedRows), rows shown \(keystrokesShown), workspace \(workspaceVisibleMs) ms, keystroke \(slowestKeystrokeMs) ms)")}
            try await Task.sleep(for:.milliseconds(600));await shoot("workspace")
            let libraryAX=await ax("game-library-listed",[["kind":"text","value":"Game library"],["kind":"text","value":"Get More Games"],["kind":"text","value":"World Championship 2024 · Ding – Gukesh"]])
            // Section headers are announced as headings, as SwiftUI's header trait made them.
            let eventHeading=libraryAX.indices.contains(2) && libraryAX[2]["role"] as? String=="AXHeading"
            if !eventHeading{failures.append("An event header is not a heading: \(libraryAX.indices.contains(2) ? libraryAX[2]:[:])")}
            library.query="fischer";try await Task.sleep(for:.milliseconds(400));await shoot("library-search");library.query=""
            library.scope = .worldChampionships;try await Task.sleep(for:.milliseconds(400));await shoot("library-championships")
            let collectionFile=URL(fileURLWithPath:directory+"/library-collection-fixture.pgn")
            try Data("[Event \"Club championship\"]\n[Site \"Leeds\"]\n[Date \"2025.03.01\"]\n[Round \"1\"]\n[White \"Ada Example\"]\n[Black \"Ben Sample\"]\n[Result \"1-0\"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0\n\n[Event \"Club championship\"]\n[Site \"Leeds\"]\n[Date \"2025.03.08\"]\n[Round \"2\"]\n[White \"Ben Sample\"]\n[Black \"Cleo Test\"]\n[Result \"1/2-1/2\"]\n\n1. d4 d5 2. c4 e6 1/2-1/2\n".utf8).write(to:collectionFile)
            library.importCollection(collectionFile);for _ in 0..<100{if !library.catalog.collections.isEmpty{break};try await Task.sleep(for:.milliseconds(100))}
            let collectionImported=library.catalog.collections.first?.1.count==2
            library.scope = .myGames;try await Task.sleep(for:.milliseconds(400))
            let collectionAX=await ax("collection-heading",[["kind":"text","value":"library-collection-fixture.pgn"]])
            let collectionHeading=collectionAX.first?["role"] as? String=="AXHeading"
            if !collectionHeading{failures.append("A collection header is not a heading: \(collectionAX)")}
            await shoot("library-my-games");library.scope = .all
            // Narrow through the square geometry: the window is re-squared from its height, so the height is what shrinks.
            var narrowed=false
            if let window=game.window{let wide=window.frame;var narrow=wide;narrow.size.height=max(window.minSize.height,wide.height*0.7);narrow.origin.y=wide.maxY-narrow.size.height;window.setFrame(narrow,display:true);try await Task.sleep(for:.milliseconds(700))
                narrowed=window.frame.width<wide.width-100 && abs(window.frame.width-window.frame.height-(wide.width-wide.height))<=2
                if !narrowed{failures.append("Narrow library window stayed \(Int(window.frame.width)) points wide (was \(Int(wide.width)))")}
                await shoot("library-narrow");window.setFrame(wide,display:true);try await Task.sleep(for:.milliseconds(500))}
            var graphReady=false,staleLibraryOpenDropped=false
            // An open whose read is overtaken by navigation (back to practice) never opens: the newer activity stands.
            if let row=library.catalog.classics.first(where:{$0.id=="library:lasker-thomas"}) {
                library.open(row);model.practice();try await Task.sleep(for:.milliseconds(1500))
                staleLibraryOpenDropped=model.review.document?.provenance != GameLibrary.provenance && !model.importingReview && !model.reviewWorkspace
                if !staleLibraryOpenDropped{failures.append("A library open overtaken by navigation still opened")}
                model.showReviewWorkspace();try await Task.sleep(for:.milliseconds(500))
            }
            // A then B: B is asked for while A is still being parsed, and B's read is held (automation barrier) until well
            // after A's parse would have finished. A must never present, and B must open once released.
            var newestOpenWins=false
            if let a=library.catalog.classics.first(where:{$0.id=="library:immortal"}),let b=library.catalog.classics.first(where:{$0.id=="library:lasker-thomas"}) {
                model.automationReviewImportDelayMs=1200
                library.open(a);for _ in 0..<100{if model.importingReview{break};try await Task.sleep(for:.milliseconds(10))}
                let aParsing=model.importingReview
                library.automationHoldReads=true;library.open(b);try await Task.sleep(for:.milliseconds(2500))
                let aPresented=model.review.document?.header("White")=="Anderssen"
                library.automationReleaseReads();for _ in 0..<60{if model.review.document?.header("White")=="Edward Lasker",!model.importingReview{break};try await Task.sleep(for:.milliseconds(100))}
                let bOpened=model.review.document?.provenance==GameLibrary.provenance && model.review.document?.header("White")=="Edward Lasker"
                newestOpenWins=aParsing && !aPresented && bOpened
                model.automationReviewImportDelayMs=0
                if !newestOpenWins{failures.append("Opening B while A was parsing: A parsing \(aParsing), A presented \(aPresented), B opened \(bOpened)")}
                model.showReviewWorkspace();try await Task.sleep(for:.milliseconds(500))
            }
            // A fixed short game by id (the King Hunt), never "the last entry": the bundle's order may change.
            if let row=library.catalog.classics.first(where:{$0.id=="library:lasker-thomas"}) {
                library.open(row);for _ in 0..<100{if model.review.document?.provenance==GameLibrary.provenance{break};try await Task.sleep(for:.milliseconds(100))}
                if let d=model.review.document,d.provenance==GameLibrary.provenance{
                    game.showDetails();try await Task.sleep(for:.milliseconds(900));await shoot("overview")
                    model.reviewAnalyzer.startBatch(d);let begun=Date();while model.reviewAnalyzer.batchRunning(d.id),Date().timeIntervalSince(begun)<240{try await Task.sleep(for:.milliseconds(200))}
                    graphReady=model.reviewAnalyzer.batchStatus=="ready" && ReviewFormat.series(d,evaluations:model.reviewAnalyzer.evaluations,outcome:ReviewFormat.finalOutcome(d)).allSatisfy{$0 != nil}
                    let middle=d.mainline[d.mainline.count/2];try model.review.select(middle);try await Task.sleep(for:.milliseconds(900));await shoot("analysis")
                    try model.review.beginBranch();if let move=model.review.displayRules?.moves().first{try model.review.playBranch(move.from+move.to+(move.promotion ?? ""))};try await Task.sleep(for:.milliseconds(900));await shoot("imagined")
                    model.review.clearBranch()
                }
            }
            model.returnToGame();model.session.cancelWork()
            let paneCapturesPassed=paneCaptures.count==16 && captureDefects.isEmpty && narrowed && axPassed(libraryAX,0) && axPassed(libraryAX,1) && collectionImported && graphReady
            if !paneCapturesPassed{failures.append("Review pane captures incomplete (captures=\(paneCaptures) defects=\(captureDefects) narrowed=\(narrowed) libraryListed=\(axPassed(libraryAX,0)) collectionImported=\(collectionImported) graphReady=\(graphReady))")}
            let result:[String:Any]=["passed":failures.isEmpty,"reviewPaneCaptures":paneCapturesPassed,"staleLibraryOpenDropped":staleLibraryOpenDropped,"newestLibraryOpenWins":newestOpenWins,"libraryHeadings":eventHeading && collectionHeading,"paneCaptureSizes":paneSizes,"libraryBudgets":["phases":phases,"tableCounts":tableCounts,"keystrokeMs":keystrokeMs,"rows":timedRows,"rowsShown":keystrokesShown,"workspaceVisibleMs":workspaceVisibleMs,"slowestKeystrokeMs":slowestKeystrokeMs,"passed":budgetsPassed],"renderedImportError":renderedErrorPassed,"readableImportError":readableError,"staleChooserRejected":staleChooserPassed,"explicitReturnResumesReply":resumedOnExplicitReturn,"failedRestoreNoReplyUntilExplicitReturn":failedRestorePassed,"failedRestoreCallbacksHeld":callbacksHeld,"failedRestoreResumeWithDrawersClosed":drawersClosed && axPassed(resumeAX,1) && resumedByExplicitAction,"failedRestoreReplacementCleared":replacementCleared,"ideaMovesListed":ideaMovesListed,"noReplyDuringReview":noReplyDuringReview,"reviewVoiceRendered":reviewVoicePassed,"savedReviewRowSelected":savedRowSelected,"practiceForkParentPly0":forkPly0Verified,"practiceForkParentPly1":forkPly1Verified,"practiceForkImaginedMateDisabled":terminalLineVerified,"accessibilityChecks":axLog,"failures":failures,"geometry":geometry,"openPanelAccepted":openPanelAccepted,"openPanelCancel":openPanelCancelled,"savedRestore":savedRestorePassed,"savedLoadLesson":savedLoadLessonPassed,"savedLoadImport":savedLoadImportPassed,"savedLoadLatest":savedLoadLatestPassed,"savedLoadSameID":savedLoadSameIDPassed,"savedLoadStaleError":savedLoadErrorPassed,"staleImportCancelled":staleImportPassed,"closeFlush":closeFlushPassed,"reviewDocumentFile":model.reviewStore.documentURL(docs[0].id).path,"expectedPersistedCursor":docs[0].mainline.last!,"expectedSavedIdeas":savedIdeas.count,"pasteEntry":pastePassed,"dropCallbackEntry":dropCallbackPassed,"collectionChooser":collectionPassed,"appearances":appearances,"reducedMotionInjected":true,"defaultMotionMatchesWorkspace":defaultMotion,"accessibilitySquares":accessibleSquares.count,"mouseBranch":mouseBranchVerified,"keyboardBranch":keyboardBranchVerified,"keyboardNavigation":rightArrowVerified && leftArrowVerified,"typingFocusPreserved":typingPreserved,"hiddenPracticeMenuGuard":menuGuardPassed,"reviewAnnotationScoped":annotationRendered && annotationCleared,"fullscreenEntered":entered,"practicePreserved":preservedPractice,"blackPracticeTitle":blackPracticeTitle,"originalHashPreserved":originalHash==docs[0].contentHash,"silent":NativePolicy.silent]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:directory+"/review-ui-results.json"));NSApp.terminate(nil)
        }catch{try? JSONSerialization.data(withJSONObject:["passed":false,"error":String(describing:error)]).write(to:URL(fileURLWithPath:directory+"/review-ui-results.json"));NSApp.terminate(nil)}
    }}
    func runPawnDuelScenario(directory:String){
        guard let game=game,let model=model else{return}
        Task {
            try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
            model.lesson(3);model.learning.startPawnDuel(computer:false);game.refresh()
            try? await Task.sleep(for:.milliseconds(500))
            var clicks:[[String:Any]]=[]
            for square in ["g2","g4","f7","f5","g4","f5"] {
                let rect=game.board.squareRect(square),local=NSPoint(x:rect.midX,y:rect.midY)
                let point=game.board.convert(local,to:nil),window=game.window!
                let hit=window.contentView?.hitTest(window.contentView!.convert(point,from:nil))
                for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                    if let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1:0){NSApp.sendEvent(event)}
                    try? await Task.sleep(for:.milliseconds(80))
                }
                clicks.append(["square":square,"hit":String(describing:type(of:hit)),"selected":model.learning.picked,"turn":model.learning.miniTurn])
            }
            let board=model.learning.frame.board ?? [:]
            let passed=board["f5"]=="wp" && board["g2"]==nil && board["g4"]==nil && board["f7"]==nil && model.learning.miniTurn=="b"
            try? await game.capture(directory+"/pawn-duel.png")
            @MainActor func click(_ square:String)async {
                let rect=game.board.squareRect(square),point=game.board.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)
                for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                    if let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:game.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1:0){NSApp.sendEvent(event)}
                    try? await Task.sleep(for:.milliseconds(80))
                }
            }
            game.showDetails();try? await Task.sleep(for:.milliseconds(850))
            var games:[[String:Any]]=[]
            for kind in MiniGameKind.allCases {
                if let lesson=model.learning.library.lessons.firstIndex(where:{$0.id==kind.lessonID}){model.lesson(lesson)}
                model.learning.startMini(kind,restart:true);game.refresh();try? await Task.sleep(for:.milliseconds(100))
                if let move=MiniGameRules.moves(board:model.learning.miniGame!.board,kind:kind,side:"w").first {
                    await click(move.from);await click(move.to)
                    for _ in 0..<150 where model.learning.miniThinking{try? await Task.sleep(for:.milliseconds(40))}
                    try? await Task.sleep(for:.milliseconds(750))
                    let played=kind.solo ? model.learning.miniGame?.history.count==1:model.learning.miniGame?.history.count==2 && model.learning.miniTurn=="w"
                    games.append(["id":kind.rawValue,"passed":played,"computer":model.learning.miniGame?.computer ?? false])
                    try? await game.capture(directory+"/"+kind.rawValue+".png")
                } else {games.append(["id":kind.rawValue,"passed":false])}
            }
            // WI-018: a game won by a clicked move opens its review sheet with the proved fact; Return closes it, and a
            // new game shows none. D5, with the voice double: Read Aloud, clicked with pointer events, opens a reading of
            // that review alone, which asks only for the fact's exact text as a script; Return also ends the reading.
            // The sheet's buttons in their window, leading first: SwiftUI hosts each as an AppKit control without a title
            // or identifier, so the reading control (Read Aloud, then Stop Reading) is the one before Done.
            @MainActor func buttons(_ root:NSView?)->[NSPoint] {
                func find(_ view:NSView)->[NSView] {(view is NSControl && !view.isHidden ? [view]:[])+view.subviews.flatMap(find)}
                return (root.map(find) ?? []).map{$0.convert($0.bounds,to:nil)}.sorted{$0.minX<$1.minX}.map{NSPoint(x:$0.midX,y:$0.midY)}
            }
            @MainActor func press(_ point:NSPoint,in sheet:NSWindow)async {
                for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                    if let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:sheet.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1:0){NSApp.sendEvent(event)}
                    try? await Task.sleep(for:.milliseconds(80))
                }
            }
            final class Requests {var scripts:[String]=[],other=0}
            var reading:[String:Any]=["offered":false]
            var almost=MiniGameState(kind:.rookSweep);almost.snapshot.board=["a1":"wr","h2":"wp","e5":"br","a7":"bp"]
            model.session.state.miniGames?[MiniGameKind.rookSweep.rawValue]=almost
            if let lesson=model.learning.library.lessons.firstIndex(where:{$0.id==MiniGameKind.rookSweep.lessonID}){model.lesson(lesson)}
            model.learning.startMini(.rookSweep);game.refresh();try? await Task.sleep(for:.milliseconds(100))
            await click("a1");await click("a7")
            for _ in 0..<150 where !game.miniReviewSheetShown{try? await Task.sleep(for:.milliseconds(40))}
            let sheetShown=game.miniReviewSheetShown,facts=model.learning.miniReview.review?.facts.map(\.text) ?? []
            if let sheet=game.window?.attachedSheet {
                try? await GameWindow.captureWindow(sheet,path:directory+"/mini-review.png")
                let requests=Requests()
                model.voice.requestObserver={event in if let response=event["response"] as? [String:Any],response["conversation"] as? String=="none",let text=(response["instructions"] as? String)?.components(separatedBy:"SCRIPT:\n").last{requests.scripts.append(text)}else{requests.other+=1}}
                let offered=buttons(sheet.contentView);reading["buttons"]=offered.count
                if offered.count==2 {
                    // A learner who already agreed to the voice coach; the consent question itself is VoiceConsentTests'.
                    var agreed=model.session.state.settings;agreed.voiceConsent=true;model.session.updateSettings(agreed)
                    await press(offered[0],in:sheet)
                    for _ in 0..<75 where requests.scripts.isEmpty{try? await Task.sleep(for:.milliseconds(40))}
                    try? await Task.sleep(for:.milliseconds(300))
                    reading=["offered":true,"connected":model.voice.connected && model.voice.miniReviewSession != nil,"scripts":requests.scripts,"otherRequests":requests.other,"capturing":model.voice.audio.capturing]
                    try? await GameWindow.captureWindow(sheet,path:directory+"/mini-review-reading.png")
                    // Stop Reading, in Read Aloud's place, ends the reading; Read Aloud then starts it again.
                    if let stop=buttons(sheet.contentView).first{await press(stop,in:sheet)}
                    for _ in 0..<75 where model.voice.connected{try? await Task.sleep(for:.milliseconds(40))}
                    reading["stopped"] = !model.voice.connected && model.voice.miniReviewSession==nil && model.session.voiceLease==nil
                    try? await Task.sleep(for:.milliseconds(300))
                    if let again=buttons(sheet.contentView).first{await press(again,in:sheet)}
                    for _ in 0..<75 where !model.voice.connected{try? await Task.sleep(for:.milliseconds(40))}
                    reading["readAgain"]=model.voice.connected && model.voice.miniReviewSession != nil && requests.scripts.count==2
                }
                model.voice.requestObserver=nil
                for type in [NSEvent.EventType.keyDown,.keyUp] {if let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:sheet.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36){NSApp.sendEvent(event)}}
            }
            for _ in 0..<75 where game.miniReviewSheetShown{try? await Task.sleep(for:.milliseconds(40))}
            let closed = !game.miniReviewSheetShown && !model.learning.miniReview.sheetOpen
            for _ in 0..<75 where model.voice.connected{try? await Task.sleep(for:.milliseconds(40))}
            reading["endedByReturn"] = !model.voice.connected && model.voice.miniReviewSession==nil && model.session.voiceLease==nil
            model.learning.restartMini();try? await Task.sleep(for:.milliseconds(300))
            let review:[String:Any]=["sheetShown":sheetShown,"facts":facts,"closedByReturn":closed,"noneAfterRestart":!game.miniReviewSheetShown && model.learning.miniReview.status == .idle,"readAloud":reading]
            let readAloud=reading["connected"] as? Bool==true && reading["scripts"] as? [String]==facts && reading["otherRequests"] as? Int==0 && reading["capturing"] as? Bool==false && reading["stopped"] as? Bool==true && reading["readAgain"] as? Bool==true && reading["endedByReturn"] as? Bool==true
            let reviewed=sheetShown && facts==["Move 1: you had a forced win in 1 move here."] && closed && review["noneAfterRestart"] as? Bool==true && readAloud
            let allPlayed=passed && games.count==MiniGameKind.allCases.count && games.allSatisfy{$0["passed"] as? Bool==true} && reviewed
            try? JSONSerialization.data(withJSONObject:["passed":allPlayed,"games":games,"clicks":clicks,"board":board,"review":review],options:.prettyPrinted).write(to:URL(fileURLWithPath:directory+"/pawn-duel-results.json"))
            NSApp.terminate(nil)
        }
    }
    func installMenus(window:GameWindow,model:NativeModel){let menu=NSMenu(),appItem=NSMenuItem();menu.addItem(appItem);let app=NSMenu();appItem.submenu=app
        let about=NSMenuItem(title:"About Checkmate",action:#selector(GameWindow.showAbout),keyEquivalent:"");about.target=window;app.addItem(about)
        let settings=NSMenuItem(title:"Settings…",action:#selector(GameWindow.showSettings),keyEquivalent:",");settings.target=window;app.addItem(settings);app.addItem(.separator());app.addItem(withTitle:"Hide Checkmate",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h");let hideOthers=app.addItem(withTitle:"Hide Others",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h");hideOthers.keyEquivalentModifierMask=[.command,.option];app.addItem(withTitle:"Show All",action:#selector(NSApplication.unhideAllApplications(_:)),keyEquivalent:"");app.addItem(.separator());app.addItem(withTitle:"Quit Checkmate",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let fileItem=NSMenuItem(title:"File",action:nil,keyEquivalent:""),fileMenu=NSMenu(title:"File");fileItem.submenu=fileMenu;menu.addItem(fileItem);for (title,action,key) in [("Open PGN…",#selector(openPGN),"o"),("Paste PGN or FEN",#selector(pasteReview),""),("Save Review",#selector(saveCurrentReview),"s"),("Review Current Game",#selector(reviewCurrent),"r"),("Review Previous Game",#selector(reviewPrevious),"")]{let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=self;fileMenu.addItem(item)
            // Shift-Command-R: Command-R alone is Lesson ▸ Play Step from Start.
            if action == #selector(reviewCurrent){item.keyEquivalentModifierMask=[.command,.shift]}}
        let gameItem=NSMenuItem(title:"Game",action:nil,keyEquivalent:""),gameMenu=Self.makeGameMenu(target:window);gameItem.submenu=gameMenu;menu.addItem(gameItem)
        // Lesson: the bar's playback and help, with shortcuts. Space stays with the board, which uses it to activate a square.
        let lessonItem=NSMenuItem(title:"Lesson",action:nil,keyEquivalent:""),lessonMenu=NSMenu(title:"Lesson");lessonItem.submenu=lessonMenu;menu.addItem(lessonItem)
        // In network mode the window shows only the network game's items and hides the Lesson menu (LAN-play plan D9).
        window.gameMenu=gameMenu;window.lessonMenuItem=lessonItem
        for (name,action,key,modifiers) in [("Play",#selector(GameWindow.lessonPlayPause),"p",NSEvent.ModifierFlags.command),("Previous Step",#selector(GameWindow.lessonPrevious),"[",.command),("Next Step",#selector(GameWindow.lessonNext),"]",.command),("Play Step from Start",#selector(GameWindow.lessonFromStart),"r",.command),("Hint",#selector(GameWindow.barHint),"h",[.command,.shift])] {
            let item=NSMenuItem(title:name,action:action,keyEquivalent:key);item.keyEquivalentModifierMask=modifiers;item.target=window;lessonMenu.addItem(item)
            if action == #selector(GameWindow.lessonFromStart){lessonMenu.addItem(.separator())}
        }
        let dataItem=NSMenuItem(title:"Data",action:nil,keyEquivalent:""),dataMenu=NSMenu(title:"Data");dataItem.submenu=dataMenu;menu.addItem(dataItem);let importItem=NSMenuItem(title:"Import Progress…",action:#selector(importData),keyEquivalent:""),exportItem=NSMenuItem(title:"Export Progress…",action:#selector(exportData),keyEquivalent:"");importItem.target=self;exportItem.target=self;dataMenu.addItem(importItem);dataMenu.addItem(exportItem);let backups=NSMenuItem(title:"Show Backups…",action:#selector(showBackups),keyEquivalent:"");backups.target=self;dataMenu.addItem(backups)
        let viewItem=NSMenuItem(title:"View",action:nil,keyEquivalent:""),view=NSMenu(title:"View");viewItem.submenu=view;menu.addItem(viewItem)
        for (name,action,key,modifiers) in [("Toggle Sidebar",#selector(GameWindow.toggleLeft),"s",NSEvent.ModifierFlags([.command,.shift])),("Toggle Game Details",#selector(GameWindow.toggleRight),"i",NSEvent.ModifierFlags([.command,.option]))]{let item=NSMenuItem(title:name,action:action,keyEquivalent:key);item.target=window;item.keyEquivalentModifierMask=modifiers;view.addItem(item)}
        let editItem=NSMenuItem(title:"Edit",action:nil,keyEquivalent:""),edit=NSMenu(title:"Edit");editItem.submenu=edit;menu.insertItem(editItem,at:2);for (name,selector,key) in [("Undo",NSSelectorFromString("undo:"),"z"),("Redo",NSSelectorFromString("redo:"),"Z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")]{edit.addItem(withTitle:name,action:selector,keyEquivalent:key)}
        // Workspace-scoped: Find… searches the game library and is offered only while the review workspace shows.
        edit.addItem(.separator());let find=NSMenuItem(title:"Find…",action:#selector(findInLibrary),keyEquivalent:"f");find.target=self;edit.addItem(find)
        let windowItem=NSMenuItem(title:"Window",action:nil,keyEquivalent:""),windows=NSMenu(title:"Window");windowItem.submenu=windows;menu.addItem(windowItem);windows.addItem(withTitle:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w");windows.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m");windows.addItem(withTitle:"Zoom",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"");windows.addItem(withTitle:"Bring All to Front",action:#selector(NSApplication.arrangeInFront(_:)),keyEquivalent:"");NSApp.windowsMenu=windows
        NSApp.mainMenu=menu;window.syncMenus()
    }
    /// The Game menu: practice's items, the network game's (Offer Draw, Flip Board, Leave Game), and piece inspection.
    /// Claim Draw and Resign serve both; the window shows each group only in its own mode.
    /// The Game menu, its items aimed at `target` (the window; tests read it without one).
    static func makeGameMenu(target:AnyObject?)->NSMenu {
        let gameMenu=NSMenu(title:"Game")
        for (name,action,key) in [("New Game…",#selector(GameWindow.newGame),"n"),("Take Back Move",#selector(GameWindow.undo as (GameWindow) -> () -> Void),""),("Restore Previous Game",#selector(GameWindow.restorePrevious),""),("Offer Draw",#selector(GameWindow.offerDraw),""),("Claim Draw",#selector(GameWindow.claimDraw),""),("Resign…",#selector(GameWindow.resign),""),("Flip Board",#selector(GameWindow.flipBoard),""),("Leave Game…",#selector(GameWindow.leaveGame),"")] {let item=NSMenuItem(title:name,action:action,keyEquivalent:key);item.target=target;gameMenu.addItem(item)}
        // The network game's own items carry stable identifiers for the native gates (LAN-play plan D9).
        for (action,identifier) in [(#selector(GameWindow.offerDraw),"network-menu-offer-draw"),(#selector(GameWindow.flipBoard),"network-menu-flip-board"),(#selector(GameWindow.leaveGame),"network-menu-leave-game")] {gameMenu.items.first{$0.action==action}?.identifier=NSUserInterfaceItemIdentifier(identifier)}
        gameMenu.addItem(.separator())
        for (name,action,key) in [("Protected by",#selector(GameWindow.showProtection),"p"),("Attacked by",#selector(GameWindow.showAttacks),"a")] {let item=NSMenuItem(title:name,action:action,keyEquivalent:key);item.keyEquivalentModifierMask=[.command,.shift];item.target=target;gameMenu.addItem(item)}
        let dismiss=NSMenuItem(title:"Dismiss Piece Inspection",action:#selector(GameWindow.dismissInspection),keyEquivalent:"");dismiss.target=target;gameMenu.addItem(dismiss)
        return gameMenu
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(saveCurrentReview){return model?.review.active==true && model?.deletingReviewID==nil}
        // Matches the review workspace and the training panel: nothing to review is not offered. A training game shown
        // is the current game there; an unfinished one is not reviewed (mini-games plan D6).
        if item.action == #selector(reviewCurrent){return model?.canReviewCurrent==true}
        if item.action == #selector(reviewPrevious){return model?.session.state.practice.previousGame.isEmpty==false}
        if item.action == #selector(findInLibrary){return model?.reviewWorkspace==true}
        return true
    }
    @objc func saveCurrentReview(){model?.saveCurrentReview()}
    @objc func openPGN(){model?.openPGN()}
    @objc func findInLibrary(){guard model?.reviewWorkspace==true else{return};model?.library.requestFind()}
    @objc func pasteReview(){model?.pasteReview()}
    @objc func reviewCurrent(){model?.reviewCurrent()}
    @objc func reviewPrevious(){model?.reviewCurrent(previous:true)}
    @objc func importData(){model?.importState()}
    @objc func showBackups(){model?.showBackups()}
    @objc func exportData(){model?.exportState()}
    func applicationDidHide(_ notification:Notification){model?.setAway(true)}
    func applicationDidUnhide(_ notification:Notification){model?.setAway(game?.window?.isMiniaturized==true)}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool{game?.showWindow(nil);return true}
    /// Finder's Open With and a drop on the Dock icon open a PGN for review; files opened before the window exists wait.
    private var pendingOpen:[URL]=[]
    lazy var reviewFiles:ReviewFileReader={let reader=ReviewFileReader();reader.activity={[weak self] in self?.model?.activityGeneration ?? -1};reader.supersede={[weak self] in self?.model?.supersedeReviewOpen()};return reader}()
    /// Several files opened at once: the learner picks the one to review (one review is open at a time); nil cancels.
    var chooseReviewFile:([URL])->URL?=AppDelegate.askWhichFile
    static func askWhichFile(_ urls:[URL])->URL? {let alert=NSAlert();alert.messageText="Choose a file to review";alert.informativeText="\(urls.count) files were opened. Checkmate reviews one at a time.";let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:440,height:28));picker.setAccessibilityLabel("File to review");for url in urls{picker.addItem(withTitle:String(url.lastPathComponent.prefix(256)))};alert.accessoryView=picker;alert.addButton(withTitle:"Review");alert.addButton(withTitle:"Cancel");return alert.runModal() == .alertFirstButtonReturn ? urls[picker.indexOfSelectedItem]:nil}
    func application(_ application:NSApplication,open urls:[URL]){pendingOpen+=urls;openPendingFiles()}
    private func openPendingFiles(){
        guard let model,!pendingOpen.isEmpty else{return};let urls=pendingOpen;pendingOpen.removeAll()
        guard let url=urls.count==1 ? urls[0]:chooseReviewFile(urls) else{return}
        let file=url.resolvingSymlinksInPath()
        guard let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]),values.isRegularFile==true,let size=values.fileSize,size<=ReviewPolicy.maximumBytes else{model.storageError="This file could not be opened for review. Use a PGN or FEN file up to 16 MiB.";return}
        reviewFiles.load(file,deliver:{[weak model] in model?.importReviewData($0)},failed:{[weak model] in model?.storageError="This file could not be read."})
    }
    /// A draft review holding the learner's imagined lines is never discarded without asking. A seated network player
    /// is asked last, just before closing, since leaving resigns; once everything agrees, the network game is left and the app waits until
    /// the resignation, or the host's `ended`, has gone out (LAN-play plan D9).
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard let model else{return .terminateNow}
        // The network question goes last: a guest may take a waiting host's seat while an earlier dialog is open.
        guard model.mayQuitDuringLessonJob(),model.resolveDraftBeforeLeaving(),model.mayQuitAfterSaving(),model.mayQuitNetworkGame() else{return .terminateCancel}
        return model.closeNetworkSession(then:{NSApp.reply(toApplicationShouldTerminate:true)}) ? .terminateLater:.terminateNow
    }
    func applicationWillTerminate(_ notification:Notification){model?.shutdown();if lockDescriptor>=0{Darwin.close(lockDescriptor)}}
    /// Waits until a transition reaches its end state, polling every 50 ms. The deadline only bounds liveness:
    /// the caller still asserts the state, so a transition that never arrives fails rather than passes.
    func settle(seconds:Double,_ done:()->Bool) async {let deadline=Date().addingTimeInterval(seconds);while !done() && Date()<deadline{try? await Task.sleep(for:.milliseconds(50))}}
    func runFullscreen(directory:String){guard let game=game else{return};try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true);Task{try? await Task.sleep(nanoseconds:500_000_000);game.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);if game.window!.styleMask.contains(.fullScreen){game.window?.toggleFullScreen(nil);try? await Task.sleep(nanoseconds:2_000_000_000)};let normal=game.window!.frame;var frames:[[String:Any]]=[];game.window?.toggleFullScreen(nil);await settle(seconds:6){game.window!.styleMask.contains(.fullScreen) && game.window!.frame==game.window!.screen!.frame};let expected=[CGFloat(0),game.leftExtent,game.leftExtent+game.rightExtent,game.rightExtent,CGFloat(0)];for (index,(name,action)) in [("closed",{}),("left",{game.toggleLeft()}),("both",{game.toggleRight()}),("right",{game.toggleLeft()}),("closed-again",{game.toggleRight()})].enumerated(){action();await settle(seconds:5){abs(game.main.view.frame.width-(game.split.view.frame.width-expected[index]))<=1};frames.append(["phase":name,"window":NSStringFromRect(game.window!.frame),"split":NSStringFromRect(game.split.view.frame),"main":NSStringFromRect(game.main.view.frame),"windowWidth":game.window!.frame.width,"splitWidth":game.split.view.frame.width,"mainWidth":game.main.view.frame.width,"fullscreen":game.window!.styleMask.contains(.fullScreen)]);try? await game.capture(directory+"/fullscreen-"+name+".png")};game.window?.toggleFullScreen(nil);await settle(seconds:6){!game.window!.styleMask.contains(.fullScreen) && abs(game.window!.frame.width-normal.width)<=1 && abs(game.window!.frame.height-normal.height)<=1};let restored=game.window!.frame;let correct=abs(restored.width-normal.width)<=1 && abs(restored.height-normal.height)<=1;let geometryCorrect=frames.enumerated().allSatisfy{i,frame in guard let width=frame["windowWidth"] as? CGFloat,let split=frame["splitWidth"] as? CGFloat,let main=frame["mainWidth"] as? CGFloat else{return false};return abs(width-split)<=1 && abs(main-(split-expected[i]))<=1};try? JSONSerialization.data(withJSONObject:["passed":correct && geometryCorrect && (frames.first?["fullscreen"] as? Bool ?? false),"geometryCorrect":geometryCorrect,"restored":correct,"entered":frames.first?["fullscreen"] as? Bool ?? false,"frames":frames],options:.prettyPrinted).write(to:URL(fileURLWithPath:directory+"/fullscreen-results.json"));try? await game.capture(directory+"/normal-restored.png")}}
    func runScenario(directory:String){guard let game=game,let model=model else{return};try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        Task {try? await Task.sleep(nanoseconds:500_000_000);if game.window!.styleMask.contains(.fullScreen){game.window?.toggleFullScreen(nil);try? await Task.sleep(nanoseconds:2_000_000_000)};var failures:[String]=[];let initial=game.window!.frame
            let screen=game.window!.screen!.visibleFrame,initialBoard=game.board.boardRect
            var geometry:[[String:Any]]=[["phase":"initial","window":NSStringFromRect(initial),"board":NSStringFromRect(game.board.frame),"main":NSStringFromRect(game.main.view.frame),"screen":NSStringFromRect(screen)]]
            for _ in 0..<20 {game.toggleLeft();try? await Task.sleep(nanoseconds:850_000_000);game.toggleRight();try? await Task.sleep(nanoseconds:850_000_000);if abs(game.board.boardRect.width-initialBoard.width)>1{failures.append("Board changed size during drawer cycle")};geometry.append(["phase":"toggle","window":NSStringFromRect(game.window!.frame),"board":NSStringFromRect(game.board.frame),"main":NSStringFromRect(game.main.view.frame)])}
            for _ in 0..<12{game.toggleLeft();game.toggleRight();try? await Task.sleep(nanoseconds:40_000_000)};try? await Task.sleep(nanoseconds:2_000_000_000)
            if abs(game.window!.frame.width-initial.width)>1{failures.append("Drawer endpoints drift")}
            try? await game.capture(directory+"/practice.png")
            let practiceBeforeWorkspace=model.session.rules.fen,libraryBeforeWorkspace=model.reviews.count
            model.showReviewWorkspace();if !game.desiredLeft{game.toggleLeft()};try? await Task.sleep(for:.milliseconds(900))
            if model.review.active || model.reviews.count != libraryBeforeWorkspace || model.session.rules.fen != practiceBeforeWorkspace{failures.append("Review workspace created a record or changed practice")}
            try? await game.capture(directory+"/review-workspace.png")
            model.practice();model.reviewCurrent()
            // The current game is parsed off the main thread (under the import overlay): wait for it to open.
            for _ in 0..<200 where model.importingReview || !model.review.active{try? await Task.sleep(for:.milliseconds(25))}
            if !model.review.active || !model.reviewDraft || model.reviews.count != libraryBeforeWorkspace{failures.append("Opening current game saved without intent")}
            let saveShortcut=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:game.window!.windowNumber,context:nil,characters:"s",charactersIgnoringModifiers:"s",isARepeat:false,keyCode:1)!
            if NSApp.mainMenu?.performKeyEquivalent(with:saveShortcut) != true || model.reviewDraft || model.reviews.count != libraryBeforeWorkspace+1{failures.append("Command-S did not explicitly save the review")}
            model.practice();game.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);try? await Task.sleep(for:.milliseconds(200))
            if game.window?.isKeyWindow != true{failures.append("Overlay scenario could not activate the board window")}
            try? model.session.select("g1");game.window?.makeFirstResponder(game.board);game.refresh()
            model.session.annotate(arrows:[["g1","f3"],["d2","d4"]],highlights:[]);try? await Task.sleep(for:.milliseconds(100));try? await game.capture(directory+"/board-overlays-low.png")
            if game.window?.isKeyWindow != true{failures.append("Board window lost key focus before the breathing check: another app took focus")}else if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !game.board.breathing{failures.append("Selected piece did not start breathing")}
            try? await Task.sleep(for:.milliseconds(1300));try? await game.capture(directory+"/board-overlays-high.png")
            game.board.isHidden=true;if game.board.breathing{failures.append("Hidden board kept its breathing timer")};game.board.isHidden=false
            game.board.selected=nil;if game.board.breathing{failures.append("Cleared selection kept its breathing timer")}
            @MainActor func inspectionKey(_ character:String,_ code:UInt16){game.board.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:game.window!.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code)!)}
            game.refresh();inspectionKey("p",35);if game.relationships.report?.mode != .protected{failures.append("P did not show protection")}
            try? await Task.sleep(for:.milliseconds(850));try? await game.capture(directory+"/protected-start.png")
            let unchanged=model.session.rules.fen;game.select("h3");if model.session.rules.fen == unchanged || game.relationships.mode != nil{failures.append("A legal destination clicked during inspection did not leave inspection and play")}
            game.dismissInspection();model.session.clearSelection();do{try model.session.rules.reset()}catch{failures.append("The board could not be reset")}
            try? model.session.rules.load("k3q3/3PR3/8/8/6b1/8/8/4K3 w - - 0 1");try? model.session.inspectPiece("d7");game.refresh()
            let menuKey=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command,.shift],timestamp:0,windowNumber:game.window!.windowNumber,context:nil,characters:"P",charactersIgnoringModifiers:"p",isARepeat:false,keyCode:35)!
            if NSApp.mainMenu?.performKeyEquivalent(with:menuKey) != true{failures.append("Protection menu shortcut did not route")}
            if game.relationships.report?.relations.first(where:{$0.square=="e7"})?.status != "conditional"{failures.append("Conditional protection missing")}
            try? await Task.sleep(for:.milliseconds(200));try? await game.capture(directory+"/protected-conditional.png")
            inspectionKey("a",0);if game.relationships.report?.mode != .attacked{failures.append("A did not show attacks")}
            try? await Task.sleep(for:.milliseconds(200));try? await game.capture(directory+"/attacked.png")
            inspectionKey("",53);if game.relationships.mode != nil{failures.append("Escape did not dismiss relationships")};if model.session.selected != "d7"{failures.append("Escape unexpectedly cleared selected piece")}
            do{try model.session.rules.reset()}catch{failures.append("The board could not be reset")};model.session.clearSelection();game.refresh()
            if game.desiredRight{game.toggleRight();try? await Task.sleep(for:.milliseconds(850))}
            let lessonBoardWidth=game.main.view.frame.width
            model.lesson(0);model.learning.seek(step:0);try? await Task.sleep(for:.milliseconds(850))
            if !game.desiredRight || game.inspectorItem.isCollapsed{failures.append("Entering a lesson did not open details")}
            if abs(game.main.view.frame.width-lessonBoardWidth)>1{failures.append("Lesson details changed board width")}
            game.toggleRight();try? await Task.sleep(for:.milliseconds(850));model.learning.seek(step:1);try? await Task.sleep(for:.milliseconds(100))
            if game.desiredRight{failures.append("Transcript navigation reopened manually closed lesson details")}
            model.lesson(0);model.learning.seek(step:0);try? await Task.sleep(for:.milliseconds(850));try? await game.capture(directory+"/lesson-welcome.png")
            let explanation=model.learning.current.beats.firstIndex{$0.id=="intro:15"}!
            model.learning.seek(step:explanation);model.learning.play();game.showDetails();try? await Task.sleep(for:.milliseconds(850));try? await game.capture(directory+"/lesson-explanation.png")
            let kingRect=game.board.squareRect("e1"),kingPoint=game.board.convert(NSPoint(x:kingRect.midX,y:kingRect.midY),to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp]{if let event=NSEvent.mouseEvent(with:type,location:kingPoint,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:game.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1:0){NSApp.sendEvent(event)};try? await Task.sleep(for:.milliseconds(80))}
            if !model.learning.playing || !model.learning.picked.isEmpty{failures.append("Lesson board click interrupted narration or created an answer")}
            model.learning.advance(by:model.learning.duration)
            if model.learning.key != "intro:16" || !model.learning.playing{failures.append("Lesson did not continue to the next explanation")}
            try? await game.capture(directory+"/lesson-continued.png")
            model.puzzles();try? await Task.sleep(nanoseconds:200_000_000);try? await game.capture(directory+"/puzzles.png");model.learning.openPuzzle(id:"extra-1");model.learning.click("f3");model.learning.click("h4");if !model.learning.passed{failures.append("Puzzle capture failed")}
            model.practice();try? model.session.demonstrate(title:"Central pawns",introduction:"Imagine making room for your pieces.",lines:[DemoLineInput(label:"Opening",moves:[DemoStepInput(uci:"e2e4"),DemoStepInput(uci:"e7e5")])]);try? model.session.seekDemo(line:0,ply:2);try? await Task.sleep(nanoseconds:200_000_000);try? await game.capture(directory+"/demonstration.png");model.session.closePresentation();game.showSettings();try? await Task.sleep(nanoseconds:200_000_000);try? await GameWindow.captureWindow(game.settings?.window,path:directory+"/settings-board.png")
            game.settings?.selectCategory("Voice Coach");try? await Task.sleep(nanoseconds:200_000_000);try? await GameWindow.captureWindow(game.settings?.window,path:directory+"/settings-voice.png")
            game.settings?.selectCategory("Connections");try? await Task.sleep(nanoseconds:200_000_000);try? await GameWindow.captureWindow(game.settings?.window,path:directory+"/settings-connections.png")
            game.settings?.selectCategory("About");try? await Task.sleep(nanoseconds:200_000_000);try? await GameWindow.captureWindow(game.settings?.window,path:directory+"/settings-about.png")
            game.settings?.close();game.window?.makeKeyAndOrderFront(nil)
            let shortcut=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:game.window!.windowNumber,context:nil,characters:",",charactersIgnoringModifiers:",",isARepeat:false,keyCode:43)!
            if NSApp.mainMenu?.performKeyEquivalent(with:shortcut) != true || game.settings?.window?.isVisible != true {failures.append("Command-comma menu routing failed")}
            game.settings?.close();game.window?.appearance=NSAppearance(named:.darkAqua);try? await Task.sleep(nanoseconds:200_000_000);try? await game.capture(directory+"/practice-dark.png")
            model.practice();try? model.session.select("g1");game.window?.makeKeyAndOrderFront(nil);game.window?.makeFirstResponder(game.board);game.refresh();model.session.annotate(arrows:[["g1","f3"],["d2","d4"]],highlights:[])
            try? await Task.sleep(for:.milliseconds(300));try? await game.capture(directory+"/board-overlays-dark.png")
            game.showSettings();try? await Task.sleep(for:.milliseconds(100));if game.board.breathing{failures.append("Inactive window kept its breathing timer")}
            game.settings?.close();game.window?.makeKeyAndOrderFront(nil);game.board.selected=nil
            model.session.clearSelection();model.session.state.settings.coachingMode="quiet"
            if game.desiredRight{game.toggleRight();try? await Task.sleep(for:.milliseconds(850))}
            model.voice.receive(["type":"session.updated"]);try? await Task.sleep(for:.milliseconds(850))
            if !game.desiredRight{failures.append("Voice connection did not open game details")}
            model.voice.receive(["type":"conversation.item.input_audio_transcription.completed","item_id":"learner-preview","transcript":"How is my knight protected?"])
            model.voice.receive(["type":"response.output_audio_transcript.done","response_id":"coach-preview","transcript":"Press P to see which pieces protect your knight."])
            try? await Task.sleep(for:.milliseconds(200));try? await game.capture(directory+"/voice-transcript.png")
            game.toggleRight();try? await Task.sleep(for:.milliseconds(850))
            model.voice.receive(["type":"response.output_audio_transcript.done","response_id":"coach-latest","transcript":"The newest explanation stays at the top."])
            try? await Task.sleep(for:.milliseconds(200));if game.desiredRight{failures.append("Transcript update reopened manually closed drawer")}
            model.voice.disconnect();if game.desiredRight{failures.append("Disconnect changed drawer visibility")}
            model.voice.receive(["type":"session.updated"]);try? await Task.sleep(for:.milliseconds(850));if !game.desiredRight{failures.append("Voice reconnection did not reopen drawer")};model.voice.disconnect()
            NSApp.activate(ignoringOtherApps:true);game.window?.makeKeyAndOrderFront(nil);game.window?.makeKey()
            model.session.clearSelection();model.session.annotate(arrows:[["d2","d4"],["g1","f3"]],highlights:[])
            try? await Task.sleep(for:.milliseconds(120));if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !game.board.animatingArrow{failures.append("Move arrow did not animate without selection: key=\(game.window?.isKeyWindow == true) visible=\(game.window?.isVisible == true) hidden=\(game.board.isHiddenOrHasHiddenAncestor) arrow=\(String(describing:game.board.primaryMoveArrow)) relationship=\(String(describing:game.board.relationshipMode)) mode=\(model.session.mode)")}
            try? await game.capture(directory+"/arrow-flow-a.png");try? await Task.sleep(for:.milliseconds(400));try? await game.capture(directory+"/arrow-flow-b.png")
            for theme in ["wood","green","blue","neutral"] {
                model.session.state.settings.boardTheme=theme;game.refresh()
                model.session.annotate(arrows:[["e2","e3"],["g1","f3"],["d2","d4"]],highlights:[])
                for (appearance,label) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                    game.window?.appearance=NSAppearance(named:appearance);try? await Task.sleep(for:.milliseconds(120))
                    try? await game.capture(directory+"/palette-"+theme+"-"+label+".png")
                }
            }
            game.board.isHidden=true;if game.board.animatingArrow{failures.append("Hidden board kept arrow animation")};game.board.isHidden=false
            game.showSettings();try? await Task.sleep(for:.milliseconds(100));if game.board.animatingArrow{failures.append("Inactive window kept arrow animation")};game.settings?.close();game.window?.makeKeyAndOrderFront(nil)
            model.session.clearAnnotations();model.session.emit(semantic:false);try? await Task.sleep(for:.milliseconds(100));if game.board.animatingArrow{failures.append("Cleared arrows kept animation")}
            try? JSONSerialization.data(withJSONObject:["failures":failures,"passed":failures.isEmpty,"geometry":geometry],options:.prettyPrinted).write(to:URL(fileURLWithPath:directory+"/ui-results.json"))
        }
    }
}
@main struct CheckmateApplication {
    @MainActor static func main(){
if let i=CommandLine.arguments.firstIndex(of:"--data-dir"),i+1<CommandLine.arguments.count{setenv("CHECKMATE_DATA_DIR",CommandLine.arguments[i+1],1)}
// One window, never tabs: View ▸ Show Tab Bar would make the board area non-square.
NSWindow.allowsAutomaticWindowTabbing=false
let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=AppDelegate();app.delegate=delegate;app.run()

    }
}
