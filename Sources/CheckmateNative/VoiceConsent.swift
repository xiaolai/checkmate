import AppKit
import CheckmateSupport

/// The learner's answer to the voice consent sheet: connect (and whether to connect again at launch), or not now.
enum VoiceConsentAnswer:Equatable {case cancel,connect(autoConnect:Bool)}

/// The one-time question before the voice coach first reaches OpenAI, by Connect, Read Aloud, Preview or Check
/// availability (V-1): what is sent, to whom, on whose plan, and when the microphone listens.
@MainActor enum VoiceConsent {
    /// The About pane's sentence, so the two never disagree.
    static let sentToOpenAI="When the voice coach is connected, what you say and the current position are sent to OpenAI, authorized by your Codex sign-in."
    static let explanation=sentToOpenAI+" It uses your ChatGPT plan through Codex. The microphone is on only while the voice coach is connected; disconnect it at any time."
    static let autoConnectLabel="Connect voice coach on launch"

    /// Shows the question as a sheet on the front window (or as a window when there is none) and replies once.
    static func ask(autoConnect:Bool,reply:@escaping (VoiceConsentAnswer)->Void){
        let alert=NSAlert();alert.messageText="Use the voice coach with OpenAI?";alert.informativeText=explanation
        let connect=alert.addButton(withTitle:"Agree");connect.setAccessibilityIdentifier("voice-consent-connect")
        let cancel=alert.addButton(withTitle:"Cancel");cancel.setAccessibilityIdentifier("voice-consent-cancel")
        alert.showsSuppressionButton=true
        if let box=alert.suppressionButton{box.title=autoConnectLabel;box.state=autoConnect ? .on:.off;box.setAccessibilityIdentifier("voice-consent-auto")}
        let answer:(NSApplication.ModalResponse)->Void={response in reply(response == .alertFirstButtonReturn ? .connect(autoConnect:alert.suppressionButton?.state == .on):.cancel)}
        if let window=NSApp.keyWindow ?? NSApp.mainWindow{alert.beginSheetModal(for:window,completionHandler:answer)}else{answer(alert.runModal())}
    }
}
