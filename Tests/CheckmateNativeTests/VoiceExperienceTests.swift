import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// The voice coach around its conversation: a typed question (V-3), one action per failure that opens the right place
/// (V-6, V-27), Game menu items (V-20), VoiceOver announcements (V-21), plain usage numbers (V-16) and thinking levels
/// (V-28). Silent: a voice double answers, and links are recorded instead of opened.
@MainActor final class VoiceExperienceTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func model()throws->NativeModel {let model=try NativeModel();model.askVoiceConsent={_,reply in reply(.connect(autoConnect:false))};return model}
    private func waitFor(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<300 {if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail(what)}

    /// Every action a failure offers goes to one place: System Settings, the Codex page, a Settings pane, or a retry.
    func testEveryActionOpensItsPlace()throws {
        let model=try model();defer{model.shutdown()};let help=model.voiceHelp
        var opened:[URL]=[],panes:[SettingsCategory]=[],retries=0
        help.openURL={opened.append($0)};help.showSettings={panes.append($0)}
        for action in VoiceAction.allCases {help.perform(action){retries+=1}}
        XCTAssertEqual(opened,[VoiceHelp.microphoneSettings,VoiceHelp.getCodex]);XCTAssertEqual(panes,[.voice,.connections,.voice,.connections])
        XCTAssertEqual(retries,1,"only Try Again tries again")
        XCTAssertEqual(VoiceHelp.microphoneSettings.scheme,"x-apple.systempreferences");XCTAssertEqual(VoiceHelp.getCodex.scheme,"https")
    }
    /// Automation records a link in the data directory instead of opening a browser or System Settings.
    func testLinksAreRecordedDuringAutomation()throws {
        let model=try model();defer{model.shutdown()}
        model.voiceHelp.perform(.getCodex){};model.voiceHelp.perform(.openMicrophoneSettings){}
        let log=try String(contentsOf:model.store.directory.appendingPathComponent("opened-urls.txt"),encoding:.utf8)
        XCTAssertEqual(log,VoiceHelp.getCodex.absoluteString+"\n"+VoiceHelp.microphoneSettings.absoluteString+"\n")
    }
    /// V-3: a typed question asks for consent, connects without a greeting, and is asked once the coach is ready.
    func testATypedQuestionConnectsThenAsks()async throws {
        let model=try model();defer{model.shutdown()};let voice=model.voice;voice.voiceDouble=true;var sent:[[String:Any]]=[]
        voice.automationOutbound={sent.append($0)}
        model.voiceHelp.ask("   ");XCTAssertEqual(voice.connectRequests,[],"an empty question connects nothing")
        model.voiceHelp.ask("Why is my knight bad on the rim?")
        XCTAssertTrue(model.session.state.settings.voiceConsent,"the question asked for consent first");XCTAssertEqual(voice.connectRequests,[false],"no greeting before a question")
        try await waitFor("the question is asked"){voice.history.contains{$0.role=="learner" && $0.text=="Why is my knight bad on the rim?"}}
        XCTAssertNil(model.voiceHelp.pendingQuestion)
        XCTAssertTrue(sent.contains{($0["item"] as? [String:Any]).flatMap{($0["content"] as? [[String:Any]])?.first?["text"] as? String}=="Why is my knight bad on the rim?"})
        // Connected, the next question goes straight in.
        model.voiceHelp.ask("And now?");XCTAssertEqual(voice.connectRequests,[false]);XCTAssertTrue(voice.history.contains{$0.text=="And now?"})
    }
    /// A question waiting for a connection that fails is dropped, never asked later by surprise.
    func testAQuestionWaitingForAFailedConnectionIsDropped()async throws {
        let model=try model();defer{model.shutdown()};let voice=model.voice
        voice.automationAuthorizationFailure=VoiceFailure.offline
        model.voiceHelp.ask("Is this move safe?");XCTAssertEqual(model.voiceHelp.pendingQuestion,"Is this move safe?")
        try await waitFor("the connection fails"){voice.failure != nil}
        try await waitFor("the question is dropped"){model.voiceHelp.pendingQuestion==nil}
        XCTAssertEqual(voice.failure,.offline)
    }
    /// A typed question stays in the field until the coach receives it: a connection that fails, at once or later,
    /// keeps the learner's words; a delivered question clears the field.
    func testATypedQuestionStaysUntilDelivered()async throws {
        let model=try model();defer{model.shutdown()};let voice=model.voice,help=model.voiceHelp
        voice.automationAuthorizationFailure=VoiceFailure.offline
        help.draft="Is this move safe?";help.submit();XCTAssertEqual(help.pendingQuestion,"Is this move safe?")
        try await waitFor("the connection fails"){voice.failure != nil}
        try await waitFor("the question is dropped"){help.pendingQuestion==nil}
        XCTAssertEqual(help.draft,"Is this move safe?","a failed connection keeps the question")
        // Refused before connecting (Codex holds the session): nothing waits, and the words stay.
        voice.automationAuthorizationFailure=nil;model.session.setConnection(enabled:true,role:"coach")
        help.submit();XCTAssertFalse(voice.connecting);XCTAssertNil(help.pendingQuestion)
        XCTAssertEqual(help.draft,"Is this move safe?","an immediate refusal keeps the question")
        model.session.setConnection(enabled:false,role:"coach")
        // Delivered: the field clears once the coach has the question.
        voice.voiceDouble=true;help.submit()
        try await waitFor("the question is asked"){voice.history.contains{$0.role=="learner" && $0.text=="Is this move safe?"}}
        XCTAssertEqual(help.draft,"","a delivered question clears the field")
        // Connected, a question goes straight in and clears; whitespace alone sends nothing and stays.
        help.draft="And now?";help.submit();XCTAssertEqual(help.draft,"");XCTAssertTrue(voice.history.contains{$0.text=="And now?"})
        help.draft="  ";help.submit();XCTAssertEqual(help.draft,"  ")
    }
    /// V-21: a voice failure and the coach's answer reach VoiceOver.
    func testFailuresAndAnswersAreAnnounced()async throws {
        let model=try model();defer{model.shutdown()};var heard:[String]=[];model.voiceHelp.announce={heard.append($0)}
        model.voice.automationAuthorizationFailure=VoiceFailure.signInExpired;model.connectPracticeVoice()
        try await waitFor("the failure is announced"){heard.contains(VoiceFailure.signInExpired.cause)}
        model.voice.automationAuthorizationFailure=nil;model.voice.voiceDouble=true;model.connectPracticeVoice()
        try await waitFor("ready"){model.voice.connected}
        model.voice.receive(["type":"response.output_audio_transcript.done","item_id":"coach-1","transcript":"Your knight controls more squares in the centre."])
        try await waitFor("the answer is announced"){heard.contains("Your knight controls more squares in the centre.")}
    }
    /// V-20: the Game menu offers the coach in practice and hides it in a network game, which has its own Connect.
    func testTheGameMenuOffersTheCoach(){
        let menu=AppDelegate.makeGameMenu(target:nil)
        let connect=menu.items.first{$0.action==#selector(GameWindow.toggleVoiceCoach)},stop=menu.items.first{$0.action==#selector(GameWindow.stopSpeaking)}
        XCTAssertEqual(connect?.title,"Connect Voice Coach");XCTAssertEqual(stop?.title,"Stop Speaking");XCTAssertEqual(stop?.keyEquivalent,".");XCTAssertEqual(stop?.keyEquivalentModifierMask,[.command])
        GameWindow.syncMenus(menu,lesson:nil,network:true);XCTAssertEqual(connect?.isHidden,true);XCTAssertEqual(stop?.isHidden,true)
        GameWindow.syncMenus(menu,lesson:nil,network:false);XCTAssertEqual(connect?.isHidden,false);XCTAssertEqual(stop?.isHidden,false)
    }
    /// V-20: the menu item's title follows the connection, and Stop Speaking is enabled only while the coach talks.
    func testTheVoiceMenuItemsFollowTheCoach()async throws {
        let model=try model();defer{model.shutdown()};model.voice.voiceDouble=true
        let connect=NSMenuItem(title:"Connect Voice Coach",action:#selector(GameWindow.toggleVoiceCoach),keyEquivalent:""),stop=NSMenuItem(title:"Stop Speaking",action:#selector(GameWindow.stopSpeaking),keyEquivalent:".")
        XCTAssertEqual(GameWindow.voiceMenuItemEnabled(connect,model:model,offered:true),true);XCTAssertEqual(connect.title,"Connect Voice Coach")
        XCTAssertEqual(GameWindow.voiceMenuItemEnabled(connect,model:model,offered:false),false,"not offered here, so not enabled")
        XCTAssertEqual(GameWindow.voiceMenuItemEnabled(stop,model:model,offered:true),false)
        model.connectPracticeVoice();try await waitFor("ready"){model.voice.connected}
        XCTAssertEqual(GameWindow.voiceMenuItemEnabled(connect,model:model,offered:false),true,"a connected coach can always be disconnected");XCTAssertEqual(connect.title,"Disconnect Voice Coach")
        XCTAssertNil(GameWindow.voiceMenuItemEnabled(NSMenuItem(title:"Other",action:#selector(GameWindow.newGame),keyEquivalent:""),model:model,offered:true))
    }
    /// V-16: usage reads as plain numbers.
    func testUsageReadsAsPlainNumbers(){
        XCTAssertEqual(UsageFormat.tokens(45210),"45,210 tokens");XCTAssertEqual(UsageFormat.tokens(1),"1 token")
        XCTAssertEqual(UsageFormat.minutes(30),"under a minute");XCTAssertEqual(UsageFormat.minutes(60),"1 minute");XCTAssertEqual(UsageFormat.minutes(754),"13 minutes")
        XCTAssertEqual(UsageFormat.dollars(0.0034),"less than $0.01");XCTAssertEqual(UsageFormat.dollars(1.234),"$1.23");XCTAssertEqual(UsageFormat.dollars(0),"$0.00")
        XCTAssertEqual(UsageFormat.credits(0.004),"less than 0.01");XCTAssertEqual(UsageFormat.credits(12.5),"12.50")
        XCTAssertEqual(UsageFormat.summary(tokens:45210,seconds:754,uses:3),"3 uses · 45,210 tokens · 13 minutes");XCTAssertEqual(UsageFormat.summary(tokens:nil,seconds:nil,uses:1),"1 use")
        XCTAssertEqual(UsageFormat.summary(tokens:nil,seconds:nil,uses:0),"None")
    }
    /// V-28: the learner picks how long the coach thinks; any other effort chosen under Advanced shows as Custom.
    func testThinkingLevelsMapToEfforts(){
        XCTAssertEqual(VoiceSettingsContent.thinking(effort:"minimal"),.quick);XCTAssertEqual(VoiceSettingsContent.thinking(effort:"high"),.thorough)
        XCTAssertNil(VoiceSettingsContent.thinking(effort:"medium"),"medium is offered only under Advanced")
    }
    /// V-5: without Codex or its sign-in, Settings explains what is needed and the drawer offers Get Codex, not Connect.
    func testWithoutCodexTheCoachIsExplained()throws {
        let model=try model();defer{model.shutdown()}
        XCTAssertEqual(VoiceSettingsContent.needs(nil),[],"nothing is claimed before the check");XCTAssertEqual(VoiceSettingsContent.needs(VoiceCapability(codexInstalled:true,signInFileFound:true)),[])
        let needs=VoiceSettingsContent.needs(VoiceCapability(codexInstalled:false,signInFileFound:false))
        XCTAssertEqual(needs.count,2);XCTAssertTrue(needs[0].contains("Codex"));XCTAssertTrue(needs[1].contains("ChatGPT"))
        XCTAssertEqual(VoiceSettingsContent.needs(VoiceCapability(codexInstalled:true,signInFileFound:false)).count,1)
        model.voice.refreshCapability{VoiceCapability(codexInstalled:false,signInFileFound:false)}
        XCTAssertEqual(VoiceCoachCard.offer(model.voice),.getCodex);model.voice.refreshCapability{VoiceCapability(codexInstalled:true,signInFileFound:true)}
        XCTAssertEqual(VoiceCoachCard.offer(model.voice),.connect)
    }
    /// V-14: after Set Up Codex, the next step depends on whether Codex connections are already allowed; V-25: the
    /// training coach says its help counts before the learner connects it.
    func testSetupAndTrainingCaptionsSayTheNextStep(){
        XCTAssertTrue(SettingsWindow.setupReady(connectionsAllowed:false,skill:"checkmate").contains("Turn on Allow Codex connections"))
        XCTAssertEqual(SettingsWindow.setupReady(connectionsAllowed:true,skill:"checkmate"),"Ready. Start a new Codex task using $checkmate.")
        for text in [SettingsWindow.setupReady(connectionsAllowed:false,skill:"x"),TrainingVoiceCoach.helpCaption]{XCTAssertFalse(text.contains("MCP"),text)}
        XCTAssertTrue(TrainingVoiceCoach.helpCaption.contains("solved with help"))
    }
    /// V-27: Settings opens on the pane asked for.
    func testSettingsOpenOnTheCategoryAskedFor()throws {
        let model=try model();defer{model.shutdown()};let settings=SettingsWindow(model:model)
        settings.show(category:.connections);XCTAssertEqual(settings.shownCategory,.connections)
        settings.show(category:.voice);XCTAssertEqual(settings.shownCategory,.voice);settings.close()
    }
}
