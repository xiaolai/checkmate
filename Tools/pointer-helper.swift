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
// The scroll area a wheel at this point reaches first: the hit element itself or its nearest scroll area.
func scrollArea(at p:CGPoint)->AXUIElement?{var hit:AXUIElement?;guard AXUIElementCopyElementAtPosition(app,Float(p.x),Float(p.y),&hit) == .success,let hit else{return nil};if get(hit,kAXRoleAttribute) as? String=="AXScrollArea"{return hit};return ancestor(hit,"AXScrollArea",stop:"AXWindow")}
// A wheel over a nested scroll area turns that one, so the point must hit the area itself: its middle when that does,
// else the middle of an edge of its visible part, else the middle as before.
func wheelPoint(_ area:AXUIElement,_ visible:CGRect)->CGPoint{let mid=CGPoint(x:visible.midX,y:visible.midY),edge:CGFloat=min(8,visible.width/4,visible.height/4)
    let candidates=[mid,CGPoint(x:visible.midX,y:visible.minY+edge),CGPoint(x:visible.midX,y:visible.maxY-edge),CGPoint(x:visible.minX+edge,y:visible.midY),CGPoint(x:visible.maxX-edge,y:visible.midY)]
    return candidates.first{scrollArea(at:$0).map{CFEqual($0,area)} ?? false} ?? mid}
func clamp(_ p:CGPoint,_ r:CGRect)->CGPoint{CGPoint(x:min(max(p.x,r.minX),r.maxX),y:min(max(p.y,r.minY),r.maxY))}
func reveal(_ e:AXUIElement?){guard let e=e,let w=windowOf(e),let wf=frame(w) else{return}
    let areas=scrollAreas(e);var visible=wf.insetBy(dx:0,dy:40).offsetBy(dx:0,dy:20)
    for (index,area) in areas.enumerated(){
        guard let af=frame(area) else{return};visible=visible.intersection(af.insetBy(dx:0,dy:4))
        guard !visible.isNull,visible.width>0,visible.height>0 else{fputs("Scroll area \(af) has no visible part in window \(wf)\n",stderr);exit(2)}
        let p=wheelPoint(area,visible),inner=areas[(index+1)...]
        func target()->CGPoint?{guard let f=frame(e) else{return nil};let room=inner.compactMap(frame).reduce(CGRect.infinite){$0.intersection($1.insetBy(dx:0,dy:4))};let c=CGPoint(x:f.midX,y:f.midY);return room.isNull ? c:clamp(c,room)}
        var shown=false
        // The 61st look follows the 60th scroll, so a last scroll that reveals the element counts.
        for attempt in 0...60{guard let t=target() else{return};if visible.contains(t){shown=true;break};if attempt==60{break};unobstructed(p);post(.mouseMoved,p)
            let lines=Int32(max(2,min(10,abs(t.y-p.y)/40)));let wheel=made(CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:1,wheel1:t.y>p.y ? -lines:lines,wheel2:0,wheel3:0),"scroll");wheel.location=p;wheel.post(tap:.cghidEventTap);usleep(60_000)}
        if !shown{fputs("Not visible after scrolling: element \(frame(e).map{"\($0)"} ?? "without a frame") visible region \(visible)\n",stderr);exit(2)}
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
case "return":key(36)
// Whether a control accepts input, as AXEnabled reports it.
case "enabled":guard let e=element(a) else{fputs("Not found: \(a)\n",stderr);exit(2)};print((get(e,kAXEnabledAttribute) as? Bool) ?? false)
// Clicks a button inside the window that shows the given text: an alert's Cancel, never another window's.
case "dialog-click":
    guard let window=(get(app,kAXWindowsAttribute) as? [AXUIElement])?.first(where:{w in find(w){_,n in n.contains(a)} != nil}) else{fputs("No window shows: \(a)\n",stderr);exit(2)}
    click(center(find(window){role,n in role=="AXButton" && n.contains(b)},b))
case "go-folder":key(5,flags:[.maskCommand,.maskShift]);usleep(250_000);type(a);key(36);usleep(350_000)
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
default:fputs("Unknown action\n",stderr);exit(1)
}
