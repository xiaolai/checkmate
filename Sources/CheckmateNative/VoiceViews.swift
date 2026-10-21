import SwiftUI
import CheckmateCore

/// A failure's cause and its one button (V-6, V-27). `retry` is what Try Again does here.
struct VoiceFailureNote:View {
    let failure:VoiceFailure
    let help:VoiceHelp
    let retry:()->Void
    var body:some View {
        Text(failure.cause).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("voice-failure")
        if let action=failure.action {Button(action.title){help.perform(action,retry:retry)}.accessibilityIdentifier("voice-failure-action")}
    }
}

/// The practice drawer's voice coach (V-3, V-4, V-20): what the coach is for and Connect while it is off; its
/// conversation, a typed question, Stop Speaking and Disconnect while it is on.
struct VoiceCoachCard:View {
    enum Offer:Equatable {case connect,getCodex}
    /// Connect when voice could work on this Mac; Get Codex when the check found neither Codex nor its sign-in (V-5).
    @MainActor static func offer(_ voice:VoiceCoach)->Offer {voice.capability?.usable==false ? .getCodex:.connect}
    @ObservedObject var voice:VoiceCoach
    let model:NativeModel
    @ObservedObject private var help:VoiceHelp
    init(voice:VoiceCoach,model:NativeModel){self.voice=voice;self.model=model;_help=ObservedObject(wrappedValue:model.voiceHelp)}
    private var idle:Bool {voice.connection == .disconnected && voice.history.isEmpty}
    var body:some View {
        Divider();Text("Voice Coach").sectionHeading()
        if idle {
            Text("Ask about this game out loud or in writing, and the coach answers about the position on the board.").fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:2){Text("“Why was my last move a mistake?”");Text("“What should I be thinking about here?”")}.font(.callout).foregroundStyle(.secondary)
        }
        let unavailable=voice.practiceVoiceUnavailability
        if voice.connected {
            Text(voice.status).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VoiceCoachControls(voice:voice,idPrefix:"voice",actions:[.init(id:"recheck",title:"Check That Again"){voice.recheck()}])
        } else if voice.connecting {
            Text(voice.status).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VoiceCoachControls(voice:voice,idPrefix:"voice")
        } else {
            if let failure=voice.failure {VoiceFailureNote(failure:failure,help:model.voiceHelp){model.connectPracticeVoice()}}
            else if !idle,voice.connection != .disconnected {Text(voice.status).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            switch Self.offer(voice) {
            case .getCodex:
                Text(VoiceUnavailability.codexMissing.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Button(VoiceAction.getCodex.title){model.voiceHelp.perform(.getCodex){}}.accessibilityIdentifier("voice-get-codex")
            case .connect:
                VoiceCoachControls(voice:voice,idPrefix:"voice"){model.connectPracticeVoice()}.disabled(unavailable != nil)
                // V-9: a disabled control says why.
                if let unavailable {Text(unavailable.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            }
        }
        if unavailable == nil || voice.connected {
            TextField("Ask the Coach…",text:$help.draft).onSubmit{help.submit()}.disabled(voice.connecting).accessibilityIdentifier("voice-ask")
        }
        ForEach(Array(voice.history.reversed())){entry in VStack(alignment:.leading){Text(entry.role=="learner" ? "You":"Coach").font(.caption).foregroundStyle(.secondary);Text(entry.text).textSelection(.enabled)}}
    }
}

/// Settings ▸ Voice Coach (V-5, V-9, V-28): what voice needs, how long the coach thinks, speech and the microphone.
struct VoiceSettingsContent:View {
    /// The learner's level for an effort; nil for an effort only Advanced offers.
    static func thinking(effort:String)->CoachThinking? {CoachThinking(rawValue:effort)}
    /// What this Mac still needs for voice, one line each; nothing before the check, or when voice can work.
    static func needs(_ capability:VoiceCapability?)->[String] {
        guard let capability,!capability.signInFileFound else{return []}
        return (capability.codexInstalled ? []:["The Codex app from OpenAI, installed on this Mac."])+["A Codex sign-in with your ChatGPT account."]
    }
    @ObservedObject var session:GameSession
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var voiceAudio:VoiceAudio
    @ObservedObject var preview:VoicePreview
    let model:NativeModel
    @State private var advanced:Bool
    init(session:GameSession,voice:VoiceCoach,voiceAudio:VoiceAudio,preview:VoicePreview,model:NativeModel){
        self.session=session;self.voice=voice;self.voiceAudio=voiceAudio;self.preview=preview;self.model=model
        _advanced=State(initialValue:Self.thinking(effort:session.state.settings.coachReasoningEffort)==nil)
    }
    private func binding<T>(_ key:WritableKeyPath<AppSettings,T>)->Binding<T> {Binding(get:{session.state.settings[keyPath:key]},set:{var s=session.state.settings;s[keyPath:key]=$0;session.updateSettings(s)})}
    var body:some View {
        let settings=session.state.settings,needs=Self.needs(voice.capability)
        if !needs.isEmpty {
            Section("What You Need"){
                ForEach(needs,id:\.self){Label($0,symbol:.markerOff)}
                if voice.capability?.codexInstalled==false{Button(VoiceAction.getCodex.title){model.voiceHelp.perform(.getCodex){}}.accessibilityIdentifier("voice-settings-get-codex")}
                Text("Checkmate checks again whenever you come back to it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Connection"){
            Text(voice.status);Text(voice.availability).foregroundStyle(.secondary)
            if let failure=voice.availabilityFailure{VoiceFailureNote(failure:failure,help:model.voiceHelp){model.checkVoiceAvailability()}}
            else if let failure=voice.failure,!voice.connected,!voice.connecting{VoiceFailureNote(failure:failure,help:model.voiceHelp){model.connectVoiceFromSettings()}}
            HStack{
                Button("Check Availability"){model.checkVoiceAvailability()}.disabled(voice.checkingAvailability || voice.connecting || voice.connected)
                VoiceCoachControls(voice:voice,idPrefix:"voice-settings"){model.connectVoiceFromSettings()}.disabled(session.companionEnabled)
            }
            // V-9: why a control is off.
            if session.companionEnabled{Text("Connect is off while Codex is connected to Checkmate. Turn off Allow Codex connections in Connections to use voice.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            else if voice.connected || voice.connecting{Text("Check Availability is off while the coach is connected.").font(.caption).foregroundStyle(.secondary)}
            Toggle(VoiceConsent.autoConnectLabel,isOn:binding(\.voiceAutoConnect))
            Text("Voice is off until you connect it and agree to what is sent to OpenAI. After that, if this is on, Checkmate checks once at launch whether your Codex sign-in can use voice, and connects only when your account allows it.").foregroundStyle(.secondary)
        }
        Section("Thinking"){
            Picker("Thinking",selection:binding(\.coachReasoningEffort)){
                ForEach(CoachThinking.allCases,id:\.self){Text($0.title).tag($0.rawValue)}
                if Self.thinking(effort:settings.coachReasoningEffort)==nil{Text("Custom: \(CoachThinking.name(effort:settings.coachReasoningEffort))").tag(settings.coachReasoningEffort)}
            }.accessibilityIdentifier("coach-thinking")
            Text(Self.thinking(effort:settings.coachReasoningEffort)?.detail ?? "Chosen under Advanced.").font(.caption).foregroundStyle(.secondary)
            Toggle("Show Advanced Settings",isOn:$advanced).accessibilityIdentifier("coach-advanced")
            if advanced {
                Text(voice.selectedModel.isEmpty ? "Coach: chosen automatically, the newest one your account can use":"Coach: chosen automatically · \(voice.selectedModel)").foregroundStyle(.secondary)
                Picker("Reasoning effort",selection:binding(\.coachReasoningEffort)){ForEach(AppSettings.reasoningEfforts,id:\.self){Text(CoachThinking.name(effort:$0)).tag($0)}}.accessibilityIdentifier("coach-reasoning-effort")
                Text("Longer thinking may take longer to answer and uses more of your account. Changes apply to the next answer.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Speech"){
            Picker("Voice",selection:binding(\.coachVoice)){ForEach(AppSettings.voices,id:\.self){Text($0.capitalized).tag($0)}}
            if voice.connected && voice.activeVoice != settings.coachVoice{Text("Reconnect to use the selected voice.").font(.caption).foregroundStyle(.secondary)}
            Picker("Response language",selection:binding(\.voiceLanguage)){ForEach(AppSettings.languages.keys.sorted(),id:\.self){Text(AppSettings.languages[$0]!).tag($0)}}
            Slider(value:binding(\.voiceVolume),in:0...1){Text("Coach volume")}
            Button(preview.playing ? "Stop Preview":"Preview Voice"){model.previewVoice()}.accessibilityIdentifier("coach-voice-preview")
            if !preview.status.isEmpty{Text(preview.status).font(.caption).foregroundStyle(.secondary)}
        }
        Section {
            ProgressView(value:voiceAudio.level,total:1).accessibilityLabel("Microphone input level")
            Button("Test Microphone"){voice.testMicrophone()}.disabled(voice.connected || voice.connecting)
            if voice.connected || voice.connecting{Text("Disconnect the coach to test the microphone.").font(.caption).foregroundStyle(.secondary)}
            if let failure=voice.microphoneFailure{VoiceFailureNote(failure:failure,help:model.voiceHelp){voice.testMicrophone()}}
            Toggle("Microphone",isOn:binding(\.voiceMicrophone))
            Picker("Input device",selection:binding(\.voiceInputDevice)){Text("System default").tag("");ForEach(VoiceAudio.devices()){Text($0.name).tag($0.id)}}.disabled(!settings.voiceMicrophone)
            Picker("Spoken language",selection:binding(\.voiceInputLanguage)){Text("Detect automatically").tag("auto");Text("Same as response language").tag("response")}.disabled(!settings.voiceMicrophone)
            if !settings.voiceMicrophone{Text("Turn on Microphone to choose a device and a spoken language.").font(.caption).foregroundStyle(.secondary)}
            Toggle("Allow the coach to play a move you ask for",isOn:binding(\.voiceAssistMoves))
        } header:{Text("Learner input")} footer:{Text("Where echo cancellation is available, speak to interrupt the coach; otherwise the microphone pauses while the coach speaks. Assisted moves require your spoken request.")}
    }
}
