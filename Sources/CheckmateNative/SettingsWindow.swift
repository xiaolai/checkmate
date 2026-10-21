import AppKit
import SwiftUI
import CheckmateCore
private enum SettingsCategory:String,CaseIterable,Identifiable {case board="Chessboard",sound="Sound",lessons="Lessons",practice="Practice",voice="Voice Coach",connections="Connections",usage="Usage",about="About";var id:String{rawValue};var symbol:String{switch self{case .board:return "checkerboard.rectangle";case .sound:return "speaker.wave.2";case .lessons:return "book";case .practice:return "flag.checkered";case .voice:return "waveform";case .connections:return "link";case .usage:return "chart.bar";case .about:return "info.circle"}}}
private final class SettingsSelection:ObservableObject {@Published var category:SettingsCategory? = .board}
private struct SettingsSidebar:View {@ObservedObject var selection:SettingsSelection;var body:some View{List(SettingsCategory.allCases,selection:$selection.category){c in Label(c.rawValue,systemImage:c.symbol).tag(c)}.listStyle(.sidebar).scrollContentBackground(.hidden)}}
private struct SettingsForm:View {
    @ObservedObject var selection:SettingsSelection
    @ObservedObject var session:GameSession
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var companion:CompanionBroker
    @State private var companionSetupStatus = ""
    /// The first line Codex wrote when Set up or Remove failed, shown under Details.
    @State private var companionSetupDetails:String?
    @State private var companionSetupRunning = false
    /// The consent sheet, the voice connection and the Codex registration check live on the model.
    let model:NativeModel
    @State private var codexSetup:CompanionInstallation.SetupCheck?
    @ObservedObject var voiceAudio:VoiceAudio
    @ObservedObject var preview:VoicePreview
    let about:AboutFacts
    let lessonLanguages:LessonLanguageController
    let usage:UsageLedger
    let library:CourseLibrary
    func binding<T>(_ key:WritableKeyPath<AppSettings,T>)->Binding<T> {Binding(get:{session.state.settings[keyPath:key]},set:{var s=session.state.settings;s[keyPath:key]=$0;session.updateSettings(s)})}
    private func removeCodexSetup() {
        guard !NativePolicy.silent else {companionSetupStatus="Codex setup is disabled during automation.";return}
        guard let codex=CompanionInstallation.installedCodex() else {companionSetupStatus="Codex is not installed, so there is no Checkmate setup in it to remove.";return}
        let alert=NSAlert.destructive("Remove Checkmate from Codex?","Codex will no longer start Checkmate’s chess tools, and Checkmate’s companion skill is removed. A skill you edited is kept.",action:"Remove")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        companionSetupRunning=true;companionSetupDetails=nil
        Task {
            do {
                let skill=try Data(contentsOf:NativeResources.url("companion-skill.md"))
                let removal=try await Task.detached {try CompanionInstallation.unregister(codex:codex,bundledSkill:skill)}.value
                switch removal {case .removed:companionSetupStatus="Removed from Codex, with Checkmate’s companion skill.";case .absent:companionSetupStatus="Removed from Codex. No companion skill was installed.";case .kept:companionSetupStatus="Removed from Codex. Your edited companion skill was kept."}
            } catch {companionSetupStatus=userFacingMessage(error,fallback:"Codex setup could not be removed.");companionSetupDetails=(error as? CompanionInstallation.CodexCommandFailure)?.details}
            companionSetupRunning=false;model.refreshCodexSetup()
        }
    }
    /// Whether the installed companion skill matches this version; read only, never written at launch.
    private var skillNote:String? {
        guard let bundled=try? Data(contentsOf:NativeResources.url("companion-skill.md")) else{return nil}
        switch CompanionInstallation.skillState(bundled:bundled) {
        case .outdated:return "The installed companion skill is from an older Checkmate. Choose Set up Codex to update it."
        case .customized:return "Your companion skill differs from this version’s and is kept as it is. To use this version’s, remove ~/.codex/skills/\(CompanionInstallation.skillName()), then choose Set up Codex."
        case .notInstalled,.current:return nil
        }
    }
    private func setUpCodex() {
        guard !NativePolicy.silent else {companionSetupStatus="Codex setup is disabled during automation.";return}
        if let problem=CompanionInstallation.launchLocationProblem(bundle:Bundle.main.bundleURL) {companionSetupStatus=problem;return}
        guard let codex=CompanionInstallation.installedCodex(),let directory=Bundle.main.executableURL?.deletingLastPathComponent() else {companionSetupStatus="Install Codex on this Mac first.";return}
        let executable=directory.appendingPathComponent("CheckmateMCP")
        companionSetupRunning=true;companionSetupDetails=nil
        Task {
            do {
                let skill=try Data(contentsOf:NativeResources.url("companion-skill.md"))
                let state=try await Task.detached {try CompanionInstallation.register(executable:executable,codex:codex,skill:skill)}.value
                companionSetupStatus="Ready. Enable chess MCP connections, then start a new Codex task using $\(CompanionInstallation.skillName())."+(state == .customized ? " Your customized companion skill was kept.":"")
            } catch {companionSetupStatus=userFacingMessage(error,fallback:"Codex setup failed. Check that Codex is installed and try again.");companionSetupDetails=(error as? CompanionInstallation.CodexCommandFailure)?.details}
            companionSetupRunning=false;model.refreshCodexSetup()
        }
    }
    /// A registration Codex keeps for another copy of Checkmate (moved, renamed or deleted) is offered a repair,
    /// which registers this copy in its place.
    @ViewBuilder private var codexSetupNote:some View {
        switch codexSetup {
        case .stale(let registered)?:
            Text("Codex starts Checkmate from \(registered), which is not this copy, so chess MCP may not work.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button("Repair Codex Setup"){setUpCodex()}.disabled(companionSetupRunning).accessibilityIdentifier("repair-codex-setup")
        case .unknown?:
            Text("Checkmate could not read its entry in Codex’s configuration. If Codex cannot start Checkmate, choose Set up Codex.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        case .notSetUp?,.current?,nil:EmptyView()
        }
    }
    var body:some View {Form {
        switch selection.category ?? .board {
        case .usage:
            UsageSettingsPane(ledger:usage,controller:lessonLanguages)
        case .about:
            AboutPane(facts:about)
        case .connections:
            Section("Codex companion"){Button(companionSetupRunning ? "Working…" : "Set up Codex"){setUpCodex()}.disabled(companionSetupRunning);Button("Remove Codex Setup…"){removeCodexSetup()}.disabled(companionSetupRunning);if !companionSetupStatus.isEmpty{Text(companionSetupStatus).foregroundStyle(.secondary);if let details=companionSetupDetails{DisclosureGroup("Details"){Text(details).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}}}else if let note=skillNote{Text(note).foregroundStyle(.secondary)};codexSetupNote;Text(companion.status);Toggle("Start chess MCP on launch",isOn:binding(\.companionAutoStart));Toggle("Allow chess MCP connections",isOn:Binding(get:{companion.enabled},set:{on in if on{do{try companion.enable(role:session.state.settings.companionRole,standby:true)}catch{companion.disable()}}else{companion.disable()}}));Picker("Companion role",selection:binding(\.companionRole)){Text("Coach").tag("coach");Text("Opponent (Black)").tag("opponent")}.disabled(companion.enabled);if companion.connected{Button("Disconnect companion"){companion.disconnectCurrentClient()}};if let error=companion.error{Text(error).foregroundStyle(.secondary)}}
            Section {Text("MCP starts locally and waits for a Codex task. On launch it starts only once Set up Codex has registered Checkmate. While the voice coach is connected, Codex requests are refused with an explanation; disconnect voice to use the Codex companion.").foregroundStyle(.secondary)}
        case .voice:
            Section("Connection"){Text(voice.status);Text(voice.availability).foregroundStyle(.secondary);HStack{Button("Check availability"){model.checkVoiceAvailability()}.disabled(voice.checkingAvailability || voice.connecting || voice.connected);Button(voice.connected ? "Disconnect":voice.connecting ? "Cancel":"Connect"){if voice.connected || voice.connecting{voice.disconnect()}else{model.connectVoiceFromSettings()}}.disabled(session.companionEnabled)};Toggle(VoiceConsent.autoConnectLabel,isOn:binding(\.voiceAutoConnect));Text("Voice is off until you connect it and agree to what is sent to OpenAI. After that, if this is on, Checkmate checks Codex availability once at launch, and voice connects only when your account authorizes a session.").foregroundStyle(.secondary)}
            Section("Reasoning"){Text(voice.selectedModel.isEmpty ? "Automatic · newest compatible model":"Automatic · \(voice.selectedModel)").foregroundStyle(.secondary);Picker("Reasoning effort",selection:binding(\.coachReasoningEffort)){ForEach(AppSettings.reasoningEfforts,id:\.self){Text($0=="xhigh" ? "Extra high":$0.capitalized).tag($0)}}.accessibilityIdentifier("coach-reasoning-effort");Text("Minimal responds fastest. Higher effort allows deeper reasoning and may take longer and use more tokens. Changes apply to the next response.").font(.caption).foregroundStyle(.secondary)}
            Section("Speech"){Picker("Voice",selection:binding(\.coachVoice)){ForEach(AppSettings.voices,id:\.self){Text($0.capitalized).tag($0)}};if voice.connected && voice.activeVoice != session.state.settings.coachVoice{Text("Reconnect to use the selected voice.").font(.caption).foregroundStyle(.secondary)};Picker("Response language",selection:binding(\.voiceLanguage)){ForEach(AppSettings.languages.keys.sorted(),id:\.self){Text(AppSettings.languages[$0]!).tag($0)}};Slider(value:binding(\.voiceVolume),in:0...1){Text("Coach volume")};Button(preview.playing ? "Stop preview":"Preview voice"){model.previewVoice()}.accessibilityIdentifier("coach-voice-preview");if !preview.status.isEmpty{Text(preview.status).font(.caption).foregroundStyle(.secondary)}}
            Section {ProgressView(value:voiceAudio.level,total:1).accessibilityLabel("Microphone input level");Button("Test microphone"){voice.testMicrophone()}.disabled(voice.connected || voice.connecting);Toggle("Microphone",isOn:binding(\.voiceMicrophone));Picker("Input device",selection:binding(\.voiceInputDevice)){Text("System default").tag("");ForEach(VoiceAudio.devices()){Text($0.name).tag($0.id)}}.disabled(!session.state.settings.voiceMicrophone);Picker("Spoken language",selection:binding(\.voiceInputLanguage)){Text("Detect automatically").tag("auto");Text("Same as response language").tag("response")}.disabled(!session.state.settings.voiceMicrophone);Toggle("Allow the coach to play a move you ask for",isOn:binding(\.voiceAssistMoves))} header:{Text("Learner input")} footer:{Text("Where echo cancellation is available, speak to interrupt the coach; otherwise the microphone pauses while the coach speaks. Assisted moves require your spoken request.")}
        case .board:
            Section("Appearance"){Picker("Board theme",selection:binding(\.boardTheme)){ForEach(["wood","green","blue","neutral"],id:\.self){Text(AppSettings.themes[$0]!).tag($0)}}}
            Section("Animation"){Picker("Piece movement",selection:binding(\.pieceDuration)){Text("Off").tag(0);Text("Fast").tag(300);Text("Medium").tag(500);Text("Slow").tag(700)}}
        case .sound:
            Section("Move sounds"){Toggle("Piece and move sounds",isOn:binding(\.moveSounds));Slider(value:binding(\.effectsVolume),in:0...1){Text("Effects volume")}.disabled(!session.state.settings.moveSounds)}
        case .lessons:
            LessonSettingsPane(controller:lessonLanguages,session:session,coach:voice,library:library)
            Section {Toggle("Narration",isOn:binding(\.narration));Slider(value:binding(\.volume),in:0...1){Text("Narration volume")}.disabled(!session.state.settings.narration);Toggle("Continue automatically",isOn:binding(\.autoAdvance));Toggle("Pause for practice",isOn:binding(\.pauseForPractice))} header:{Text("Lesson playback")} footer:{Text("Bundled English narration uses OpenAI Cedar. Generated lesson recordings use your selected voice and are AI-generated. Continue automatically plays the next transcript and starts the next lesson when this one ends, skipping practice activities. Pause for practice stops at the end of a lesson that has a game or practice activity so you can try it before continuing.")}
        case .practice:
            Section("Opponent"){OpponentSettingsContent(session:session)}
            Section("Guidance"){Picker("Practice guidance",selection:binding(\.coachingMode)){Text("Guided game").tag("guided");Text("On request").tag("on_request");Text("Quiet").tag("quiet")}}
        }
    }.formStyle(.grouped).frame(minWidth:Metrics.settingsDetailMinimum,minHeight:Metrics.settingsFormMinimumHeight).onReceive(model.$codexSetup){codexSetup=$0}.onChange(of:selection.category){_,category in session.state.window.settingsCategory=category?.rawValue ?? "Chessboard";session.emit(semantic:false,save:true)}}
}
@MainActor final class SettingsWindow:NSWindowController,NSToolbarDelegate {
    /// Escape closes Settings, as ⌘W (Window ▸ Close) does.
    override func cancelOperation(_ sender:Any?){window?.performClose(sender)}
    private let selection=SettingsSelection(),titleID=NSToolbarItem.Identifier("settings.title")
    init(model:NativeModel){selection.category=SettingsCategory.allCases.first{$0.rawValue==model.session.state.window.settingsCategory} ?? .board;let w=NSWindow(contentRect:NSRect(x:0,y:0,width:Metrics.settingsWidth,height:Metrics.settingsHeight),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false);super.init(window:w)
        w.title="Settings";w.titleVisibility = .hidden;w.isReleasedWhenClosed=false;w.autorecalculatesKeyViewLoop=true
        let split=NSSplitViewController(),side=NSSplitViewItem(sidebarWithViewController:NSHostingController(rootView:SettingsSidebar(selection:selection))),detail=NSSplitViewItem(viewController:NSHostingController(rootView:SettingsForm(selection:selection,session:model.session,voice:model.voice,companion:model.companion,model:model,voiceAudio:model.voice.audio,preview:model.voicePreview,about:AboutFacts(model:model),lessonLanguages:model.lessonLanguages,usage:model.usage,library:model.learning.library)))
        side.canCollapse=false;side.minimumThickness=Metrics.settingsSidebar;side.maximumThickness=Metrics.settingsSidebar;side.allowsFullHeightLayout=true;side.titlebarSeparatorStyle = .none;detail.titlebarSeparatorStyle = .none;split.addSplitViewItem(side);split.addSplitViewItem(detail);w.contentViewController=split
        let toolbar=NSToolbar(identifier:"Settings.Toolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.centeredItemIdentifiers=[titleID];w.toolbar=toolbar;w.toolbarStyle = .unified;w.titlebarAppearsTransparent=true;w.titlebarSeparatorStyle = .none;w.setContentSize(NSSize(width:Metrics.settingsWidth,height:Metrics.settingsHeight));w.center()
    }
    func selectCategory(_ value:String){selection.category=SettingsCategory.allCases.first{$0.rawValue==value} ?? .board}
    required init?(coder:NSCoder){fatalError()}
    func toolbarDefaultItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,titleID,.flexibleSpace]}
    func toolbarAllowedItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(t)}
    func toolbar(_ t:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem?{let item=NSToolbarItem(itemIdentifier:id);item.view=textLabel("Settings",15,.semibold);item.isBordered=false;item.label="Settings";return item}
}
