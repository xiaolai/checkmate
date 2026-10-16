import AppKit
import CheckmateCore
/// The network game's app-side flows (LAN-play plan D9–D13): composition of its services, the confirmations, the quit
/// that waits for a resignation to go out, the review hand-off and the crash notice.
extension NativeModel {
    /// Network.framework and Bonjour with the build's own service type (D12). An isolated automation run may set
    /// `CHECKMATE_NETWORK_LOOPBACK_DIR` instead: listeners on 127.0.0.1, and discovery through that shared directory,
    /// where each hosting instance publishes its listeners (the `network-ui` gate).
    static func networkServices(directory:URL)->NetworkServices {
        let scheduler=NetworkQueueScheduler(),rules=NetworkRulesFactory{try ChessRules()},hashing=NetworkHashing(reviewHash)
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.0.0",crash=NetworkCrashFile(dataDirectory:directory)
        if AppDelegate.isolatedAutomation,let path=ProcessInfo.processInfo.environment[networkLoopbackVariable],!path.isEmpty {
            let shared=NetworkLoopbackDirectory(directory:URL(fileURLWithPath:path,isDirectory:true),scheduler:scheduler)
            return NetworkServices(transport:faultHook(NWNetworkTransport(scheduler:scheduler,configuration:.loopback()),scheduler:scheduler),discovery:shared.discovery(),scheduler:scheduler,delivery:.mainQueue,rules:rules,hashing:hashing,appVersion:version,crashFile:crash,listenersReady:{shared.publish($0,$1)},listenersClosed:{shared.withdraw($0)})
        }
        let type=NWNetworkTransport.bonjourServiceType()
        let discovery:any NetworkDiscovery=type.map{NWNetworkDiscovery(serviceType:$0,scheduler:scheduler)} ?? NetworkUnavailableDiscovery(scheduler:scheduler,reason:"This build declares no Bonjour service type.")
        return NetworkServices(transport:faultHook(NWNetworkTransport(scheduler:scheduler,configuration:.init(serviceType:type,loopbackOnly:false)),scheduler:scheduler),discovery:discovery,scheduler:scheduler,delivery:.mainQueue,rules:rules,hashing:hashing,appVersion:version,crashFile:crash)
    }
    static let networkLoopbackVariable="CHECKMATE_NETWORK_LOOPBACK_DIR"
    /// `--bonjour-self-check <file>` (isolated automation; scripts/prepare-bonjour.sh): this app hosts a game over real
    /// Bonjour, finds it from a second controller, and joins its seat through the real transport. That proves the
    /// local-network permission for this registered build, which a browse alone cannot: spike (c) found browsing is
    /// not gated, only connections are. The verdict goes to `file` as JSON, then the app quits.
    static func runBonjourSelfCheck(output:URL,directory:URL){
        let started=Date()
        func finish(_ result:[String:Any]){
            var verdict=result;verdict["seconds"]=Date().timeIntervalSince(started)
            verdict["bundleID"]=Bundle.main.bundleIdentifier ?? "";verdict["service"]=NWNetworkTransport.bonjourServiceType() ?? ""
            if let data=try? JSONSerialization.data(withJSONObject:verdict,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:output,options:.atomic)}
            NSApp.terminate(nil)
        }
        do {
            let host=try NetworkGameController(services:networkServices(directory:directory.appendingPathComponent("host")),playerName:"Self check")
            let guest=try NetworkGameController(services:networkServices(directory:directory.appendingPathComponent("guest")),playerName:"Guest")
            guard host.host(),let code=host.playCode,let hosted=host.hostedGameID else{return finish(["passed":false,"stage":"host","message":host.lobbyMessage ?? "could not host"])}
            guest.setShown(true)
            var stage="browse",joined=false
            func poll(_ remaining:Int){
                if guest.localNetworkDenied || host.localNetworkDenied {return finish(["passed":false,"stage":stage,"denied":true])}
                // This check's own game, by ID: another Mac's self-check may be advertising at the same moment.
                if !joined,let game=guest.games.first(where:{$0.gameID==hosted}) {
                    joined=guest.join(game,code:code.grouped);stage="join"
                    if !joined{return finish(["passed":false,"stage":stage,"message":guest.lobbyMessage ?? "could not join"])}
                }
                if joined,guest.link == .live,host.link == .live {
                    guest.leave();return finish(["passed":true,"stage":"joined","denied":false])
                }
                if case .stopped=guest.link,joined {return finish(["passed":false,"stage":stage,"message":guest.statusText ?? "stopped"])}
                guard remaining>0 else{return finish(["passed":false,"stage":stage,"message":"timed out","found":guest.games.map(\.displayName)])}
                DispatchQueue.main.asyncAfter(deadline:.now()+0.25){poll(remaining-1)}
            }
            poll(240)
        } catch {finish(["passed":false,"stage":"setup","message":"\(error)"])}
    }
    static let networkFaultVariable="CHECKMATE_NETWORK_FAULT_FILE"
    /// The gates' disconnect hook, in isolated automation only: when the file named by `CHECKMATE_NETWORK_FAULT_FILE`
    /// appears, this Mac's outbound connections drop and reconnecting is refused for the seconds the file holds
    /// (10 if it holds none), or, if it holds `stall N`, outgoing messages are held for N seconds (3 if none); the file
    /// is then removed. A gate creates it over SSH, so the control channel is never cut.
    static func faultHook(_ transport:any NetworkTransport,scheduler:any NetworkScheduler)->any NetworkTransport {
        guard AppDelegate.isolatedAutomation,let path=ProcessInfo.processInfo.environment[networkFaultVariable],!path.isEmpty else{return transport}
        let fault=NetworkFaultTransport(wrapping:transport,scheduler:scheduler),trigger=URL(fileURLWithPath:path)
        // Polls for as long as the transport lives, and no longer: a discarded one leaves no poller to take triggers.
        weak let held=fault
        func poll(){
            guard let fault=held else{return}
            if let text=try? String(contentsOf:trigger,encoding:.utf8) {
                try? FileManager.default.removeItem(at:trigger)
                let words=text.split(whereSeparator:\.isWhitespace).map(String.init)
                if words.first=="stall" {
                    fault.stall(for:.seconds(words.dropFirst().first.flatMap{Int($0)} ?? 3));NativeLog.lifecycle.notice("network fault hook: sends stalled")
                }else{
                    fault.drop(refusingFor:.seconds(words.first.flatMap{Int($0)} ?? 10));NativeLog.lifecycle.notice("network fault hook: connections dropped")
                }
            }
            _ = scheduler.schedule(at:scheduler.now + .milliseconds(250)){poll()}
        }
        scheduler.enqueue{poll()}
        return fault
    }
    /// The name offered first: the first word of the account's full name, when it is a valid network name.
    static var defaultPlayerName:String {let first=NSFullUserName().split(separator:" ").first.map(String.init) ?? "";return NetworkText.valid(first) ? first:""}

    // MARK: Leaving and resigning
    /// Leave Game (menu or pane): a seated player confirms "Leave the game? It counts as a resignation." first (D9); a
    /// spectator, a host nobody has joined, or a finished game just leaves.
    func leaveNetworkGame(){
        let game=network;guard game.part != nil else{return}
        guard game.leavingResigns else{game.leave();return}
        let session=game.sessionID
        confirmNetwork(message:NetworkGameController.leaveConfirmation,detail:"\(game.opponentName) wins the game.",action:"Leave Game",identifier:"network-leave",answer:confirmLeavingNetworkGame){[weak self] in
            // The same session only; it may have ended while the sheet was open, and leaving it then simply leaves.
            guard let game=self?.network,game.sessionID==session,game.part != nil else{return}
            game.leave()
        }
    }
    func resignNetworkGame(){
        let game=network;guard game.canResign else{return}
        let session=game.sessionID
        confirmNetwork(message:"Resign this game?",detail:"\(game.opponentName) wins. You can review the game afterwards.",action:"Resign",identifier:"network-resign",answer:confirmResigningNetworkGame){[weak self] in
            guard let game=self?.network,game.sessionID==session,game.canResign else{return}
            game.resign()
        }
    }
    /// A sheet on the window, answered for the session it was shown over. Tests inject an answer; automation without a
    /// window never blocks.
    private func confirmNetwork(message:String,detail:String,action:String,identifier:String,answer:(()->Bool)?,then confirmed:@escaping @MainActor ()->Void){
        if let answer{if answer(){confirmed()};return}
        guard let window=NSApp.mainWindow else{if NativePolicy.silent{confirmed()};return}
        let alert=NSAlert();alert.messageText=message;alert.informativeText=detail
        let go=alert.addButton(withTitle:action);go.hasDestructiveAction=true;go.setAccessibilityIdentifier(identifier+"-confirm")
        let cancel=alert.addButton(withTitle:"Cancel");cancel.keyEquivalent="\r";cancel.setAccessibilityIdentifier(identifier+"-cancel");alert.window.defaultButtonCell=cancel.cell as? NSButtonCell
        alert.beginSheetModal(for:window){response in if response == .alertFirstButtonReturn{MainActor.assumeIsolated{confirmed()}}}
    }

    // MARK: Quitting (D9)
    /// Quit or window close while seated asks first; false keeps the app open. Tests inject an answer; automation
    /// never blocks.
    func mayQuitNetworkGame()->Bool {
        guard network.leavingResigns else{return true}
        if let confirm=confirmLeavingNetworkGame{return confirm()};if NativePolicy.silent{return true}
        let alert=NSAlert();alert.messageText=NetworkGameController.leaveConfirmation
        alert.informativeText="\(network.opponentName) wins the game. Checkmate quits once your resignation has gone out."
        let quit=alert.addButton(withTitle:"Leave and Quit");quit.hasDestructiveAction=true;quit.setAccessibilityIdentifier("network-quit-confirm")
        alert.addButton(withTitle:"Cancel").setAccessibilityIdentifier("network-quit-cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Leaves an open session before the app closes, so the resignation, or the host's `ended`, goes out before the
    /// listeners close (D9, R3-2); `done` runs once it has, or after `networkLeaveDeadline`. False when there is nothing
    /// to wait for.
    func closeNetworkSession(then done:@escaping @MainActor ()->Void)->Bool {
        guard network.sessionOpen else{return false}
        var finished=false
        let finish:@MainActor ()->Void={guard !finished else{return};finished=true;done()}
        network.leave(then:finish)
        // The runners bound their own leave (2 s for a guest, 5 s for a host); this only guards the quit itself.
        Task{@MainActor in try? await Task.sleep(for:Self.networkLeaveDeadline);finish()}
        return true
    }
    static let networkLeaveDeadline=Duration.seconds(8)

    // MARK: Review and the crash notice (D9)
    /// Review this game: the record opens as a draft review through the import path.
    func reviewNetworkGame(){guard let record=network.reviewRecord() else{return};importReviewData(Data(record.utf8))}
    /// The crash file a previous run left, read once and deleted (D9): the window says its notice.
    func takeNetworkCrashNotice()->NetworkCrashFile.Entry? {
        guard let file=network.services?.crashFile,let entry=file.pending() else{return nil}
        file.clear();return entry
    }
    /// Whether the crash file's game has moves to review.
    static func reviewable(_ entry:NetworkCrashFile.Entry)->Bool {
        guard let rules=try? ChessRules(),(try? rules.restore(entry.game.pgn)) != nil else{return false}
        return !rules.history.isEmpty
    }
    func reviewNetworkCrash(_ entry:NetworkCrashFile.Entry){importReviewData(Data(NetworkGameRecord.reviewPGN(entry.game,on:Date()).utf8))}
    /// D11's help sheet button. Automation counts the request instead of opening System Settings.
    func openLocalNetworkSettings(){
        networkSettingsRequests+=1
        guard !NativePolicy.silent,let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else{return}
        NSWorkspace.shared.open(url)
    }
}
