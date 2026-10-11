import AppKit
import SwiftUI
import QuartzCore
import CheckmateCore
struct Metrics {
    static let playbackLineHeight:CGFloat=2,turnIndicatorSize:CGFloat=12,turnIndicatorOutline:CGFloat=1
    static let core:CGFloat=780,minimum:CGFloat=600,minimumFitted:CGFloat=320,left:CGFloat=216,right:CGFloat=320,header:CGFloat=52
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
struct NativeIcon:View {let symbol:String,label:String,action:()->Void;var body:some View {Button(action:action){Image(systemName:symbol)}.help(label).accessibilityLabel(label).buttonStyle(.bordered)}}
