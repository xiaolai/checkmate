// Real-pointer acceptance helper: locates accessible elements in a named PID and drives them with
// posted mouse events, so hit-testing is exercised exactly as a person's clicks and drags are.
// Accessibility "press" bypasses hit-testing and cannot catch a control that is drawn but unclickable.
import AppKit
import ApplicationServices
guard CommandLine.arguments.count>1,let parsedPID=Int32(CommandLine.arguments[1]),parsedPID>0 else{fputs("Usage: pointer-helper <pid> <action> [arguments]\n",stderr);exit(1)}
let pid=parsedPID
let app=AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app,2)
func get(_ e:AXUIElement,_ k:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,k as CFString,&v);return v}
func names(_ e:AXUIElement)->[String]{
    let own=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute,kAXIdentifierAttribute].compactMap{get(e,$0) as? String}
    let linked=(get(e,kAXTitleUIElementAttribute)).map{$0 as! AXUIElement}
    let labels=linked.map{label in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap{get(label,$0) as? String}} ?? []
    return (own+labels).filter{!$0.isEmpty}
}
// Both values must be AXValues that decode: a zeroed origin or size would aim the pointer at the wrong place.
func frame(_ e:AXUIElement)->CGRect?{guard let p=get(e,kAXPositionAttribute),let s=get(e,kAXSizeAttribute),CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else{return nil};var origin=CGPoint.zero,size=CGSize.zero;guard AXValueGetValue(p as! AXValue,.cgPoint,&origin),AXValueGetValue(s as! AXValue,.cgSize,&size) else{return nil};return CGRect(origin:origin,size:size)}
func find(_ e:AXUIElement,depth:Int=0,_ match:(String,[String])->Bool)->AXUIElement?{
    if depth>40{return nil};let role=get(e,kAXRoleAttribute) as? String ?? ""
    if depth>0,role=="AXApplication"{return nil};if depth>0,match(role,names(e)){return e}
    for child in get(e,kAXChildrenAttribute) as? [AXUIElement] ?? []{if let found=find(child,depth:depth+1,match){return found}};return nil
}
// Window content only: the closed menu bar repeats several control titles.
func inWindows(_ match:(String,[String])->Bool)->AXUIElement?{for w in get(app,kAXWindowsAttribute) as? [AXUIElement] ?? []{if let found=find(w,match){return found}};return nil}
// Controls win over their labels: a grid label often repeats its control's title.
let controls:Set<String>=["AXButton","AXLink","AXCheckBox","AXPopUpButton","AXDisclosureTriangle","AXRadioButton","AXMenuButton"]
func element(_ name:String)->AXUIElement?{inWindows{role,n in controls.contains(role) && n.contains(name)} ?? inWindows{_,n in n.contains(name)}}
func square(_ sq:String)->AXUIElement?{inWindows{role,n in role=="AXButton" && n.contains{$0==sq || $0.hasPrefix(sq+",")}}}
func center(_ e:AXUIElement?,_ what:String)->CGPoint{guard let e=e,let f=frame(e),f.width>0,f.height>0 else{fputs("Not found: \(what)\n",stderr);exit(2)};return CGPoint(x:f.midX,y:f.midY)}
let source=CGEventSource(stateID:.hidSystemState)
// An event that cannot be created stops the action (exit 4) rather than leaving it half performed.
func made(_ event:CGEvent?,_ what:String)->CGEvent{guard let event else{fputs("Could not create a \(what) event\n",stderr);exit(4)};return event}
func post(_ type:CGEventType,_ p:CGPoint){made(CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:p,mouseButton:.left),"mouse").post(tap:.cghidEventTap)}
// Moves the pointer between press and release as a trackpad press or a drag does.
func gesture(from a:CGPoint,to b:CGPoint){
    unobstructed(a);unobstructed(b);post(.mouseMoved,a);usleep(80_000);post(.leftMouseDown,a);usleep(60_000)
    let steps=max(1,Int(hypot(b.x-a.x,b.y-a.y)/4));for k in 1...steps{let t=CGFloat(k)/CGFloat(steps);post(.leftMouseDragged,CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t));usleep(12_000)}
    post(.leftMouseUp,b);usleep(150_000)
}
// The nearest parent with a role, giving up at a `stop` role or after 60 levels.
func ancestor(_ e:AXUIElement,_ role:String,stop:String?=nil)->AXUIElement? {var current=e;for _ in 0..<60{guard let parent=get(current,kAXParentAttribute) else{return nil};let p=parent as! AXUIElement;let r=get(p,kAXRoleAttribute) as? String;if r==role{return p};if let stop,r==stop{return nil};current=p};return nil}
// Some SwiftUI elements do not report their window; find it through their parents instead of skipping the scroll.
func windowOf(_ e:AXUIElement)->AXUIElement? {if let w=get(e,kAXWindowAttribute){return (w as! AXUIElement)};return ancestor(e,"AXWindow")}
// Scrolls with the wheel, as a person does, until the element sits inside its window below the toolbar.
// Scrolling, like a click, must reach this app: a wheel over another app's window scrolls that window silently.
// Far from view it turns faster, so a long list is reached within the attempts; near it, two lines at a time.
// Every scroll area holding an element clips it, so all of them count, outermost first. Each is turned over its own
// visible part (inside the window below the toolbar and inside every outer area) until the element, or the nearest
// point of the inner areas still to turn, is in view. An element in no scroll area cannot be scrolled and is left as it is.
func scrollAreas(_ e:AXUIElement)->[AXUIElement]{var areas:[AXUIElement]=[],current=e;while let area=ancestor(current,"AXScrollArea",stop:"AXWindow"){if let f=frame(area),f.width>0,f.height>0{areas.insert(area,at:0)};current=area};return areas}
// Where a wheel at a point lands relative to `area`, as hit-testing reports it: on the area or content whose nearest scroll
// area it is (direct), inside a scroll area nested in it (nested: the wheel turns that one first), or anywhere else.
enum Reach{case direct,nested,outside}
func reach(_ p:CGPoint,_ area:AXUIElement)->Reach{
    var hit:AXUIElement?;guard AXUIElementCopyElementAtPosition(app,Float(p.x),Float(p.y),&hit) == .success,var current=hit else{return .outside}
    var nested=false
    for _ in 0..<60{
        if CFEqual(current,area){return nested ? .nested:.direct}
        let role=get(current,kAXRoleAttribute) as? String
        if role=="AXWindow" || role=="AXApplication"{return .outside};if role=="AXScrollArea"{nested=true}
        guard let parent=get(current,kAXParentAttribute) else{return .outside};current=parent as! AXUIElement}
    return .outside}
// Candidate wheel points: a grid every 4 points over an area's visible part, nearest its middle first. Any exposed patch at
// least 4 by 4 points holds one, so every exposed strip at least 4 points across is reached.
let gridStep:CGFloat=4
func grid(_ r:CGRect)->[CGPoint]{var points:[CGPoint]=[]
    for y in stride(from:r.minY+gridStep/2,to:r.maxY,by:gridStep){for x in stride(from:r.minX+gridStep/2,to:r.maxX,by:gridStep){points.append(CGPoint(x:x,y:y))}}
    let c=CGPoint(x:r.midX,y:r.midY);return points.sorted{hypot($0.x-c.x,$0.y-c.y)<hypot($1.x-c.x,$1.y-c.y)}}
func describe(_ area:AXUIElement)->String{"scroll area \(names(area).first.map{"\"\($0)\""} ?? "(unnamed)") at \(frame(area).map{"\($0)"} ?? "no frame")"}
// Whether a frame changes from `before` within about 300 ms of a wheel step, as it does once the wheel turned its area.
func moved(_ before:CGRect?,_ now:()->CGRect?)->Bool{for _ in 0..<6{if now() != before{return true};usleep(50_000)};return false}
func clamp(_ p:CGPoint,_ r:CGRect)->CGPoint{CGPoint(x:min(max(p.x,r.minX),r.maxX),y:min(max(p.y,r.minY),r.maxY))}
func reveal(_ e:AXUIElement?){guard let e=e,let w=windowOf(e),let wf=frame(w) else{return}
    let areas=scrollAreas(e);var visible=wf.insetBy(dx:0,dy:40).offsetBy(dx:0,dy:20)
    for (index,area) in areas.enumerated(){
        guard let af=frame(area) else{return};visible=visible.intersection(af.insetBy(dx:0,dy:4))
        guard !visible.isNull,visible.width>0,visible.height>0 else{fputs("Scroll area \(af) has no visible part in window \(wf)\n",stderr);exit(2)}
        let points=grid(visible),inner=areas[(index+1)...],next=inner.first
        // Turning this area moves everything inside it, the next area included; a wheel that turned an inner area instead
        // moves the element but not the next area. So the next area's frame shows this area's progress, else the element's.
        func marker()->CGRect?{if let next{return frame(next)};return frame(e)}
        func target()->CGPoint?{guard let f=frame(e) else{return nil};let c=CGPoint(x:f.midX,y:f.midY)
            let room=inner.compactMap(frame).reduce(CGRect.infinite){$0.intersection($1.insetBy(dx:0,dy:4))}
            if !room.isNull{return clamp(c,room)}
            // Inner viewports that do not overlap yet: reveal the nearest part of the next one, whose own turn goes on from there.
            guard let next,let nf=frame(next) else{return c};return clamp(c,nf.insetBy(dx:0,dy:4))}
        // Only a point whose nearest scroll area is this one is wheeled at: over a nested area the wheel turns that area
        // instead. Hit-tests are made lazily and remembered, and the chosen point is tested again just before its wheel
        // step, since turning the area moves what lies under it. `spent` holds the points whose wheel step moved nothing.
        var known:[Int:Reach]=[:],spent=Set<Int>(),shown=false,stalled=false
        func verifiedPoint()->Int?{while true{
            let open=points.indices.lazy.filter{!spent.contains($0)}
            var chosen:Int?
            for i in open{let r=known[i] ?? reach(points[i],area);known[i]=r;if r == .direct{chosen=i;break}}
            guard let i=chosen else{return nil}
            let now=reach(points[i],area);known[i]=now;if now == .direct{return i}}}
        // The 61st look follows the 60th scroll, so a last scroll that reveals the element counts.
        for attempt in 0...60{guard let t=target() else{return};if visible.contains(t){shown=true;break};if attempt==60{break}
            guard let pick=verifiedPoint() else{
                if spent.isEmpty{fputs("No point in the visible region \(visible) hit-tests inside \(describe(area)), so no wheel step can be shown to reach it\n",stderr);exit(2)}
                stalled=true;break}
            let p=points[pick];unobstructed(p);post(.mouseMoved,p);let before=marker()
            let lines=Int32(max(2,min(10,abs(t.y-p.y)/40)));let wheel=made(CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:1,wheel1:t.y>p.y ? -lines:lines,wheel2:0,wheel3:0),"scroll");wheel.location=p;wheel.post(tap:.cghidEventTap);usleep(60_000)
            // A step that turned the area moved what lies under every point: earlier hit-tests no longer hold.
            if moved(before,marker){known.removeAll()}else{spent.insert(pick)}}
        if shown{continue}
        // No point turned this area further, so it is at its limit. An outer area has done its part once the next area shows
        // at all: that area's turn reveals the element or fails. The innermost area has nothing left that could.
        if stalled,let next,let nf=frame(next),!visible.intersection(nf.insetBy(dx:0,dy:4)).isEmpty{continue}
        fputs("Not visible after scrolling: element \(frame(e).map{"\($0)"} ?? "without a frame") visible region \(visible)\(stalled ? ", and no point in it turned the scroll area further":"")\n",stderr);exit(2)
    }}
// A click must land on this app: another app's window or a system prompt over the point would take it silently.
func owner(at p:CGPoint)->pid_t?{var hit:AXUIElement?;guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&hit) == .success,let hit else{return nil};var owner:pid_t=0;AXUIElementGetPid(hit,&owner);return owner}
// Only a hit-test that names this app counts: a failed lookup cannot show who would receive the event.
func unobstructed(_ p:CGPoint){for _ in 0..<3{if owner(at:p)==pid{return};NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateAllWindows]);usleep(400_000)}
    let found=owner(at:p);if found==pid{return}
    guard let other=found else{fputs("Hit-testing at \(p) found no element, so the pointer cannot be shown to reach pid \(pid)\n",stderr);exit(3)};fputs("Click at \(p) is covered by \(NSRunningApplication(processIdentifier:other)?.localizedName ?? "pid \(other)")\n",stderr);exit(3)}
func click(_ p:CGPoint){unobstructed(p);post(.mouseMoved,p);usleep(80_000);post(.leftMouseDown,p);usleep(70_000);post(.leftMouseUp,p);usleep(150_000)}
// Keys go to whichever app is focused, so they wait until this one is: otherwise exit 3, as for a covered click.
func focused()->pid_t?{var value:CFTypeRef?;guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),kAXFocusedApplicationAttribute as CFString,&value) == .success,let value else{return nil};var owner:pid_t=0;AXUIElementGetPid(value as! AXUIElement,&owner);return owner}
func requireFocus(){for _ in 0..<10{if focused()==pid{return};NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateAllWindows]);usleep(200_000)}
    if focused()==pid{return};let other=focused();fputs("Keys would reach \(other.flatMap{NSRunningApplication(processIdentifier:$0)?.localizedName} ?? "no app"), not pid \(pid)\n",stderr);exit(3)}
func key(_ code:CGKeyCode,flags:CGEventFlags=[],settle:useconds_t=200_000){requireFocus();for down in [true,false]{let event=made(CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down),"key");event.flags=down ? flags:[];event.post(tap:.cghidEventTap)};usleep(settle)}
func type(_ text:String){requireFocus();for character in text{let units=Array(String(character).utf16);for down in [true,false]{let event=made(CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:down),"key");event.flags=[];units.withUnsafeBufferPointer{buffer in if let address=buffer.baseAddress{event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:address)}};event.post(tap:.cghidEventTap)};usleep(10_000)};usleep(200_000)}
let action=CommandLine.arguments.count>2 ? CommandLine.arguments[2]:""
let a=CommandLine.arguments.count>3 ? CommandLine.arguments[3]:"",b=CommandLine.arguments.count>4 ? CommandLine.arguments[4]:""
// Reading accessibility state needs no focus, and taking it could change what a poll observes (an open menu closes).
if !["label","value","enabled","menu-open"].contains(action){NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateAllWindows]);usleep(250_000)}
switch action {
case "click":let e=element(a);reveal(e);if let e,let w=windowOf(e),let wf=frame(w),let f=frame(e),!wf.contains(CGPoint(x:f.midX,y:f.midY)){fputs("Not visible after scrolling: \(a) element \(f) window \(wf)\n",stderr);exit(2)};click(center(e,a))
// A real click a given number of points left of a named element's leading edge: the indent of a sidebar row.
case "click-left":guard let d=Double(b),d.isFinite,d>=0,d<=200 else{fputs("Offset must be 0 to 200 points, found \(b)\n",stderr);exit(1)};let e=element(a);reveal(e);guard let e,let f=frame(e) else{fputs("Not found: \(a)\n",stderr);exit(2)};click(CGPoint(x:f.minX-d,y:f.midY))
// The accessibility help (VoiceOver hint) of a named element or, failing that, of the nearest ancestor that has one.
case "help":guard var e=element(a) else{fputs("Not found: \(a)\n",stderr);exit(2)};for _ in 0..<4{if let h=get(e,kAXHelpAttribute) as? String,!h.isEmpty{print(h);exit(0)};guard let p=get(e,kAXParentAttribute) else{break};e=p as! AXUIElement};print("")
case "select-popup":
    let popup=element(a);reveal(popup);guard let popup,let bounds=frame(popup) else{fputs("Popup not found: \(a)\n",stderr);exit(2)};click(CGPoint(x:bounds.maxX-12,y:bounds.midY))
    var option:AXUIElement?
    for _ in 0..<20 {
        option=find(popup){role,n in role=="AXMenuItem" && n.contains(b)} ?? find(app){role,n in role=="AXMenuItem" && n.contains(b)}
        if option != nil{break};usleep(100_000)
    }
    if option==nil {
        fputs("Popup chosen: \(names(popup)) frame \(bounds)\n",stderr)
        func dump(_ element:AXUIElement,_ depth:Int=0){if depth>40{return};let role=get(element,kAXRoleAttribute) as? String ?? "";if (role=="AXPopUpButton" || role=="AXMenu" || role=="AXMenuItem"),(frame(element)?.width ?? 0)>0{fputs("\(role) \(names(element)) \(String(describing:frame(element)))\n",stderr)};for child in get(element,kAXChildrenAttribute) as? [AXUIElement] ?? []{dump(child,depth+1)}}
        dump(app)
    }
    click(center(option,b))
case "close-window":
    guard let window=(get(app,kAXWindowsAttribute) as? [AXUIElement])?.first(where:{names($0).contains(a)}),let button=get(window,kAXCloseButtonAttribute) else{fputs("Window not found: \(a)\n",stderr);exit(2)}
    click(center((button as! AXUIElement),a+" close button"))
case "tab":key(48)
// A shortcut: a virtual key code and modifiers named by the letters c (command), s (shift), o (option), t (control).
case "shortcut":guard let code=CGKeyCode(a) else{fputs("Key code must be a number, found \(a)\n",stderr);exit(1)};var flags:CGEventFlags=[];for m in b{switch m{case "c":flags.insert(.maskCommand);case "s":flags.insert(.maskShift);case "o":flags.insert(.maskAlternate);case "t":flags.insert(.maskControl);default:fputs("Unknown modifier \(m)\n",stderr);exit(1)}};key(code,flags:flags,settle:300_000)
case "return":key(36)
// Whether a control accepts input, as AXEnabled reports it.
// The element's screen frame as "x y width height", for checks that a control stays where it was.
case "frame":guard let e=element(a),let f=frame(e) else{fputs("Not found: \(a)\n",stderr);exit(2)};print("\(f.minX) \(f.minY) \(f.width) \(f.height)")
case "enabled":guard let e=element(a) else{fputs("Not found: \(a)\n",stderr);exit(2)};print((get(e,kAXEnabledAttribute) as? Bool) ?? false)
// Clicks a button inside the window that shows the given text: an alert's Cancel, never another window's.
case "dialog-click":
    guard let window=(get(app,kAXWindowsAttribute) as? [AXUIElement])?.first(where:{w in find(w){_,n in n.contains(a)} != nil}) else{fputs("No window shows: \(a)\n",stderr);exit(2)}
    click(center(find(window){role,n in role=="AXButton" && n.contains(b)},b))
case "go-folder":key(5,flags:[.maskCommand,.maskShift]);usleep(250_000);type(a);key(36);usleep(350_000)
// A real click, or a drag, at fractions of a named element's width (its vertical middle): a point on a graph.
case "click-at","drag-across":
    let fractions=([b]+CommandLine.arguments.dropFirst(5)).compactMap{Double($0)}.filter{$0>=0 && $0<=1}
    guard fractions.count==(action=="click-at" ? 1:2),CommandLine.arguments.count==(action=="click-at" ? 5:6) else{fputs("Fractions must be numbers from 0 to 1\n",stderr);exit(1)}
    let e=element(a);reveal(e);guard let e,let f=frame(e),f.width>0 else{fputs("Not found: \(a)\n",stderr);exit(2)}
    let points=fractions.map{CGPoint(x:f.minX+f.width*CGFloat($0),y:f.midY)};if points.count==1{click(points[0])}else{gesture(from:points[0],to:points[1])}
// A wheel turn of the given lines over a named element's centre, as a person scrolls a pane by pointing anywhere in it.
case "wheel":guard let lines=Int32(b),abs(lines)<=20 else{fputs("Scroll lines must be a whole number from -20 to 20, found \(b)\n",stderr);exit(1)};let p=center(element(a),a);unobstructed(p);post(.mouseMoved,p);usleep(80_000);let event=made(CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:1,wheel1:lines,wheel2:0,wheel3:0),"scroll");event.location=p;event.post(tap:.cghidEventTap);usleep(300_000)
case "click-square":click(center(square(a),a))
// Press a square and drift by the given distance before releasing, as a slightly moving trackpad click does.
case "drift-square":guard let d=Double(b),d.isFinite,abs(d)<=1000 else{fputs("Drift distance must be a number of points from -1000 to 1000, found \(b)\n",stderr);exit(1)};let p=center(square(a),a);gesture(from:p,to:CGPoint(x:p.x+d,y:p.y+d*0.3))
case "drag-square":gesture(from:center(square(a),a),to:center(square(b),b))
case "label":guard let e=square(a) else{fputs("Not found: \(a)\n",stderr);exit(2)};print(names(e).first ?? "")
case "value":guard let e=element(a) else{fputs("Not found: \(a)\n",stderr);exit(2)};print(get(e,kAXValueAttribute).map{"\($0)"} ?? "")
case "scroll-sidebar":guard a.isEmpty || Int32(a) != nil else{fputs("Scroll lines must be a whole number, found \(a)\n",stderr);exit(1)};guard let area=inWindows({role,n in role=="AXOutline" && n.contains("Sidebar")}),let bounds=frame(area),let window=windowOf(area),let windowBounds=frame(window) else{exit(2)};let point=CGPoint(x:bounds.minX+min(80,bounds.width/2),y:windowBounds.midY);unobstructed(point);post(.mouseMoved,point);let event=made(CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:1,wheel1:Int32(a) ?? -5,wheel2:0,wheel3:0),"scroll");event.location=point;event.post(tap:.cghidEventTap);usleep(250_000)
case "choose-menu-item":let item=find(app){role,n in role=="AXMenuItem" && n.contains(a)};click(center(item,a))
case "menu-open":print(find(app){role,n in role=="AXMenuItem" && n.contains(a)}.flatMap(frame).map{$0.width>0 && $0.height>0} ?? false)
// Opens a menu-bar menu and chooses an item, both with the pointer.
case "menu":let top=(get(app,kAXMenuBarAttribute)).flatMap{bar in find(bar as! AXUIElement){role,n in role=="AXMenuBarItem" && n.contains(a)}};click(center(top,a));usleep(250_000);click(center(top.flatMap{find($0){role,n in role=="AXMenuItem" && n.contains(b)}},b))
case "escape":key(53,settle:150_000)
// Types text into the focused control of this app, as a person types.
case "type":type(a)
// A bare key by virtual key code (125 is the down arrow).
case "key":guard let code=CGKeyCode(a) else{fputs("Key code must be a number, found \(a)\n",stderr);exit(1)};key(code)
// A real file drag and drop: this helper starts a drag of the file from a small window of its own, and posted mouse
// events carry it through the window server to the named element, where it is released. The app sees exactly what a
// drag from Finder delivers. Prints the drag operation the destination accepted ("copy", "none", ...).
case "drop-file":
    let file=URL(fileURLWithPath:a);guard FileManager.default.isReadableFile(atPath:file.path) else{fputs("No such file: \(a)\n",stderr);exit(1)}
    let target=element(b);reveal(target);let destination=center(target,b);unobstructed(destination)
    DropSession.run(file,to:destination)
default:fputs("Unknown action\n",stderr);exit(1)
}
/// The drag source of "drop-file": a 48-point window whose view begins a dragging session on the posted mouse-down.
final class DropSession:NSView,NSDraggingSource {
    var file:URL!
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation {.copy}
    override func mouseDown(with event:NSEvent){let item=NSDraggingItem(pasteboardWriter:file as NSURL);item.setDraggingFrame(bounds,contents:NSWorkspace.shared.icon(forFile:file.path));beginDraggingSession(with:[item],event:event,source:self)}
    func draggingSession(_ session:NSDraggingSession,endedAt point:NSPoint,operation:NSDragOperation){print(operation.contains(.copy) ? "copy":operation.isEmpty ? "none":"\(operation.rawValue)");exit(operation.isEmpty ? 6:0)}
    static func run(_ file:URL,to destination:CGPoint){
        let application=NSApplication.shared;application.setActivationPolicy(.accessory)
        guard let screen=NSScreen.screens.first else{fputs("No screen\n",stderr);exit(2)}
        // Top-left of the main screen, clear of the app's window centre where drops land.
        let origin=NSPoint(x:screen.frame.minX+8,y:screen.frame.maxY-120),window=NSWindow(contentRect:NSRect(origin:origin,size:NSSize(width:48,height:48)),styleMask:[.borderless],backing:.buffered,defer:false)
        let view=DropSession(frame:NSRect(x:0,y:0,width:48,height:48));view.file=file;window.contentView=view;window.level = .floating;window.orderFrontRegardless();application.activate(ignoringOtherApps:true)
        let start=CGPoint(x:origin.x+24,y:screen.frame.maxY-(origin.y+24))
        Thread.detachNewThread{
            usleep(600_000);post(.mouseMoved,start);usleep(150_000);post(.leftMouseDown,start);usleep(150_000)
            let steps=40;for k in 1...steps{let t=CGFloat(k)/CGFloat(steps);post(.leftMouseDragged,CGPoint(x:start.x+(destination.x-start.x)*t,y:start.y+(destination.y-start.y)*t));usleep(25_000)}
            usleep(300_000);post(.leftMouseDragged,destination);usleep(300_000);post(.leftMouseUp,destination)
            usleep(10_000_000);fputs("The drag did not end\n",stderr);exit(5)
        }
        application.run()
    }
}
