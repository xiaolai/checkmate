import AppKit
import SwiftUI
import QuartzCore
import CheckmateCore
/// NSHostingView can hit-test its SwiftUI subtree even while AppKit hides it.
/// Hidden title cards/libraries must never intercept the playable board underneath.
final class VisibleHostingView<Content:View>:NSHostingView<Content> {
    override func hitTest(_ point:NSPoint)->NSView? {
        guard !isHiddenOrHasHiddenAncestor else{return nil}
        return super.hitTest(point)
    }
    override func accessibilityChildren()->[Any]? {
        guard !isHiddenOrHasHiddenAncestor else{return []}
        return super.accessibilityChildren()
    }
}
struct Metrics {
    static let promotionIconSize:CGFloat=24
    static let playbackLineHeight:CGFloat=2,turnIndicatorSize:CGFloat=12,turnIndicatorOutline:CGFloat=1
    static let core:CGFloat=780,minimum:CGFloat=600,minimumFitted:CGFloat=320,left:CGFloat=216,right:CGFloat=320,header:CGFloat=52
    static let practiceIndent:CGFloat=16
    static let lessonInspectionMinimum:CGFloat=120,lessonInspectionMaximum:CGFloat=220
    static let mascotSize:CGFloat=72,settingsDetailMinimum:CGFloat=480,settingsFormMinimumHeight:CGFloat=380
    static let button:CGFloat=32,padding:CGFloat=16,smallGap:CGFloat=8,sectionGap:CGFloat=20,boardMargin:CGFloat=20,coordinateSize:CGFloat=11
    static let animation=0.7,frameInterval=1.0/60,settingsWidth:CGFloat=780,settingsHeight:CGFloat=560,settingsSidebar:CGFloat=190
}
func symbolButton(_ symbol:String,_ label:String,_ target:AnyObject,_ action:Selector)->NSButton {
    let b=NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:label)!,target:target,action:action)
    b.bezelStyle = .toolbar;b.imagePosition = .imageOnly;b.toolTip=label;b.setAccessibilityLabel(label);return b
}
func textLabel(_ text:String,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular)->NSTextField {let l=NSTextField(labelWithString:text);l.font = .systemFont(ofSize:size,weight:weight);l.lineBreakMode = .byWordWrapping;return l}
final class BackgroundView:NSView {override func draw(_ rect:NSRect){NativeColors.windowBackground.setFill();rect.fill()};override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}}
/// Hosts scrolling SwiftUI drawer content below the toolbar of a full-height split item. Left to SwiftUI, the
/// toolbar inset is applied twice there, so its hit-testing containers cover most of every button and toggle
/// they draw. AppKit's safe-area guide owns the inset instead and SwiftUI sees none.
final class ToolbarInsetHostingController<Content:View>:NSViewController {
    let hosting:NSHostingView<Content>
    init(rootView:Content){hosting=NSHostingView(rootView:rootView);super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError()}
    override func loadView(){
        let container=NSView();hosting.safeAreaRegions=[];hosting.sizingOptions=[];hosting.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(hosting)
        NSLayoutConstraint.activate([hosting.topAnchor.constraint(equalTo:container.safeAreaLayoutGuide.topAnchor),hosting.leadingAnchor.constraint(equalTo:container.leadingAnchor),hosting.trailingAnchor.constraint(equalTo:container.trailingAnchor),hosting.bottomAnchor.constraint(equalTo:container.bottomAnchor)])
        view=container
    }
}
extension NSAlert {
    /// A confirmation of something that cannot be undone: the action is marked destructive and takes no key, and
    /// Cancel (or the word given for it) is the default (Return) button and answers Escape, so only a deliberate choice runs it. The only
    /// place besides `saveChanges` an alert button is marked destructive. Responses: first the action, second Cancel, third `alternative`, a
    /// safe choice that takes no key either. `identifier` names the buttons `-confirm`, `-cancel`, `-alternative`.
    static func destructive(_ title:String,_ message:String,action:String,cancel:String="Cancel",alternative:String?=nil,identifier:String?=nil)->NSAlert {
        let alert=NSAlert();alert.messageText=title;alert.informativeText=message
        let button=alert.addButton(withTitle:action);button.keyEquivalent="";button.hasDestructiveAction=true
        let stay=alert.addButton(withTitle:cancel);stay.keyEquivalent="\r";alert.window.defaultButtonCell=stay.cell as? NSButtonCell
        alert.window.contentView?.addSubview(EscapeKey(clicking:stay))
        let other=alternative.map{alert.addButton(withTitle:$0)};other?.keyEquivalent=""
        if let identifier{button.setAccessibilityIdentifier(identifier+"-confirm");stay.setAccessibilityIdentifier(identifier+"-cancel");other?.setAccessibilityIdentifier(identifier+"-alternative")}
        return alert
    }
    /// A button holds one key, and Return is Cancel's, so Escape (which NSAlert gives only a button titled Cancel that
    /// has no other key) is carried by this invisible, unannounced button in the alert, which clicks Cancel.
    private final class EscapeKey:NSButton {
        convenience init(clicking cancel:NSButton){self.init(frame:.zero);isTransparent=true;isBordered=false;title="";keyEquivalent="\u{1b}";target=cancel;action=#selector(NSButton.performClick(_:));setAccessibilityElement(false)}
    }
    /// The Mac's save-before-closing question: Save is the default (Return), Cancel answers Escape, and Don't Save is
    /// marked destructive and takes no key. Responses: first Save, second Cancel, third Don't Save.
    static func saveChanges(_ title:String,_ message:String)->NSAlert {
        let alert=NSAlert();alert.messageText=title;alert.informativeText=message
        let save=alert.addButton(withTitle:"Save");save.keyEquivalent="\r";alert.window.defaultButtonCell=save.cell as? NSButtonCell
        alert.addButton(withTitle:"Cancel").keyEquivalent="\u{1b}"
        let discard=alert.addButton(withTitle:"Don’t Save");discard.keyEquivalent="";discard.hasDestructiveAction=true
        return alert
    }
}
extension GameWindow {
    /// What a failed learner action says. ROLE_FORBIDDEN and the other MCP contract codes are for agents; people see
    /// what they mean, never the code.
    static func failureMessage(_ error:Error)->String {
        if let app=error as? CheckmateError {
            switch app {
            case .invalid("ROLE_FORBIDDEN"):return "This move can’t be played now. Wait for your turn."
            case .invalid(let text),.unavailable(let text):if text.contains(where:\.isLetter),text.allSatisfy({$0.isUppercase || $0.isNumber || $0=="_"}){return "That action is not available right now."}
            default:break
            }
        }
        return userFacingMessage(error,fallback:"That action could not be completed.")
    }
    /// The alert for a failure: its message, and the error's recovery suggestion, when it has one, as the detail.
    static func failureAlert(_ error:Error)->NSAlert {
        let alert=NSAlert();alert.messageText=failureMessage(error)
        if let suggestion=(error as NSError).localizedRecoverySuggestion,!suggestion.isEmpty{alert.informativeText=suggestion}
        return alert
    }
    /// Shows `alert` as a sheet on the window, or app-modal when the window is gone, and hands back the choice.
    func present(_ alert:NSAlert,then handler:@escaping (NSApplication.ModalResponse)->Void={_ in}){
        if let window{alert.beginSheetModal(for:window,completionHandler:handler)}else{handler(alert.runModal())}
    }
}
