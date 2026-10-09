import AppKit
import SwiftUI
import CheckmateCore
private enum SettingsCategory:String,CaseIterable,Identifiable {case board="Chessboard",sound="Sound",lessons="Lessons",practice="Practice",voice="Voice Coach",connections="Connections";var id:String{rawValue};var symbol:String{switch self{case .board:return "checkerboard.rectangle";case .sound:return "speaker.wave.2";case .lessons:return "book";case .practice:return "flag.checkered";case .voice:return "waveform";case .connections:return "link"}}}
private final class SettingsSelection:ObservableObject {@Published var category:SettingsCategory? = .board}
private struct SettingsSidebar:View {@ObservedObject var selection:SettingsSelection;var body:some View{List(SettingsCategory.allCases,selection:$selection.category){c in Label(c.rawValue,systemImage:c.symbol).tag(c)}.listStyle(.sidebar).scrollContentBackground(.hidden)}}
private struct SettingsForm:View {
    @ObservedObject var selection:SettingsSelection
    @ObservedObject var session:GameSession
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var companion:CompanionBroker
    @State private var companionSetupStatus = ""
    @State private var companionSetupRunning = false
    @ObservedObject var voiceAudio:VoiceAudio
    func binding<T>(_ key:WritableKeyPath<AppSettings,T>)->Binding<T> {Binding(get:{session.state.settings[keyPath:key]},set:{var s=session.state.settings;s[keyPath:key]=$0;session.updateSettings(s)})}
    private func setUpCodex() {
        guard let codex=CompanionInstallation.installedCodex(),let directory=Bundle.main.executableURL?.deletingLastPathComponent() else {companionSetupStatus="Install Codex on this Mac first.";return}
        let executable=directory.appendingPathComponent("CheckmateMCP")
        companionSetupRunning=true
        Task {
            do {
                let skill=try Data(contentsOf:NativeResources.url("companion-skill.md"))
                try await Task.detached {try CompanionInstallation.register(executable:executable,codex:codex,skill:skill)}.value
                companionSetupStatus="Ready. Enable chess MCP connections, then start a new Codex task using $checkmate-companion."
            } catch {companionSetupStatus=error.localizedDescription}
            companionSetupRunning=false
        }
    }
    var body:some View {Form {
        switch selection.category ?? .board {
        case .connections:
            Section("Codex companion"){Button(companionSetupRunning ? "Setting up…" : "Set up Codex"){setUpCodex()}.disabled(companionSetupRunning);if !companionSetupStatus.isEmpty{Text(companionSetupStatus).foregroundStyle(.secondary)};Text(companion.status);Toggle("Allow chess MCP connections",isOn:Binding(get:{companion.enabled},set:{on in if on{do{try companion.enable(role:session.state.settings.companionRole)}catch{companion.disable()}}else{companion.disable()}})).disabled(voice.connected);Picker("Companion role",selection:binding(\.companionRole)){Text("Coach").tag("coach");Text("Opponent (Black)").tag("opponent")}.disabled(companion.enabled);if companion.connected{Button("Disconnect companion"){companion.release()}};if let error=companion.error{Text(error).foregroundStyle(.secondary)}}
            Section {Text("The connection stays local to this Mac. Live voice and external MCP coaching use separate, exclusive sessions.").foregroundStyle(.secondary)}
        case .voice:
            Section("Connection"){Text(voice.status);Text(voice.availability).foregroundStyle(.secondary);HStack{Button("Check availability"){voice.checkAvailability()};Button(voice.connected ? "Disconnect":"Connect"){if voice.connected{voice.disconnect()}else{voice.connect()}}.disabled(companion.enabled)};Toggle("Connect automatically in Practice",isOn:binding(\.voiceAutoConnect))}
            Section("Speech"){Picker("Voice",selection:binding(\.coachVoice)){ForEach(AppSettings.voices,id:\.self){Text($0.capitalized).tag($0)}};if voice.connected && voice.activeVoice != session.state.settings.coachVoice{Text("Reconnect to use the selected voice.").font(.caption).foregroundStyle(.secondary)};Picker("Response language",selection:binding(\.voiceLanguage)){ForEach(AppSettings.languages.keys.sorted(),id:\.self){Text(AppSettings.languages[$0]!).tag($0)}};Slider(value:binding(\.voiceVolume),in:0...1){Text("Coach volume")};Button("Preview voice"){voice.audition()}.disabled(!voice.connected)}
            Section {ProgressView(value:voiceAudio.level,total:1).accessibilityLabel("Microphone input level");Button("Test microphone"){voice.testMicrophone()}.disabled(voice.connected);Toggle("Microphone",isOn:binding(\.voiceMicrophone));Picker("Input device",selection:binding(\.voiceInputDevice)){Text("System default").tag("");ForEach(VoiceAudio.devices()){Text($0.name).tag($0.id)}}.disabled(!session.state.settings.voiceMicrophone);Toggle("Allow explicitly requested White moves",isOn:binding(\.voiceAssistMoves))} header:{Text("Learner input")} footer:{Text("The microphone pauses while the coach speaks. Assisted moves require your spoken request.")}
        case .board:
            Section("Appearance"){Picker("Board theme",selection:binding(\.boardTheme)){ForEach(["wood","green","blue","neutral"],id:\.self){Text(AppSettings.themes[$0]!).tag($0)}}}
            Section("Animation"){Picker("Piece movement",selection:binding(\.pieceDuration)){Text("Off").tag(0);Text("Fast").tag(300);Text("Medium").tag(500);Text("Slow").tag(700)}}
        case .sound:
            Section("Move sounds"){Toggle("Piece and move sounds",isOn:binding(\.moveSounds));Slider(value:binding(\.effectsVolume),in:0...1){Text("Effects volume")}.disabled(!session.state.settings.moveSounds)}
        case .lessons:
            Section {Toggle("Narration",isOn:binding(\.narration));Slider(value:binding(\.volume),in:0...1){Text("Narration volume")}.disabled(!session.state.settings.narration);Toggle("Continue automatically",isOn:binding(\.autoAdvance))} header:{Text("Lesson playback")} footer:{Text("Lesson narration uses OpenAI Cedar and is AI-generated. Continue automatically controls playback after narration. Quizzes wait for an answer, then resume after a correct answer.")}
        case .practice:
            Section("Opponent"){OpponentSettingsContent(session:session)}
            Section("Guidance"){Picker("Practice guidance",selection:binding(\.coachingMode)){Text("Guided game").tag("guided");Text("On request").tag("on_request");Text("Quiet").tag("quiet")}}
        }
    }.formStyle(.grouped).frame(minWidth:Metrics.settingsDetailMinimum,minHeight:Metrics.settingsFormMinimumHeight).onChange(of:selection.category){_,category in session.state.window.settingsCategory=category?.rawValue ?? "Chessboard";session.emit(semantic:false,save:true)}}
}
@MainActor final class SettingsWindow:NSWindowController,NSToolbarDelegate {
    private let selection=SettingsSelection(),titleID=NSToolbarItem.Identifier("settings.title")
    init(model:NativeModel){selection.category=SettingsCategory.allCases.first{$0.rawValue==model.session.state.window.settingsCategory} ?? .board;let w=NSWindow(contentRect:NSRect(x:0,y:0,width:Metrics.settingsWidth,height:Metrics.settingsHeight),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false);super.init(window:w)
        w.title="Settings";w.titleVisibility = .hidden;w.isReleasedWhenClosed=false;w.autorecalculatesKeyViewLoop=true
        let split=NSSplitViewController(),side=NSSplitViewItem(sidebarWithViewController:NSHostingController(rootView:SettingsSidebar(selection:selection))),detail=NSSplitViewItem(viewController:NSHostingController(rootView:SettingsForm(selection:selection,session:model.session,voice:model.voice,companion:model.companion,voiceAudio:model.voice.audio)))
        side.canCollapse=false;side.minimumThickness=Metrics.settingsSidebar;side.maximumThickness=Metrics.settingsSidebar;side.allowsFullHeightLayout=true;side.titlebarSeparatorStyle = .none;detail.titlebarSeparatorStyle = .none;split.addSplitViewItem(side);split.addSplitViewItem(detail);w.contentViewController=split
        let toolbar=NSToolbar(identifier:"Settings.Toolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.centeredItemIdentifiers=[titleID];w.toolbar=toolbar;w.toolbarStyle = .unified;w.titlebarAppearsTransparent=true;w.titlebarSeparatorStyle = .none;w.setContentSize(NSSize(width:Metrics.settingsWidth,height:Metrics.settingsHeight));w.center()
    }
    func selectCategory(_ value:String){selection.category=SettingsCategory.allCases.first{$0.rawValue==value} ?? .board}
    required init?(coder:NSCoder){fatalError()}
    func toolbarDefaultItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,titleID,.flexibleSpace]}
    func toolbarAllowedItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(t)}
    func toolbar(_ t:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem?{let item=NSToolbarItem(itemIdentifier:id);item.view=textLabel("Settings",15,.semibold);item.isBordered=false;item.label="Settings";return item}
}
