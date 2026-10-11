// Real-pointer acceptance helper: locates accessible elements in a named PID and drives them with
// posted mouse events, so hit-testing is exercised exactly as a person's clicks and drags are.
// Accessibility "press" bypasses hit-testing and cannot catch a control that is drawn but unclickable.
import AppKit
import ApplicationServices
let pid=Int32(CommandLine.arguments[1])!
let app=AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app,2)
func get(_ e:AXUIElement,_ k:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,k as CFString,&v);return v}
func names(_ e:AXUIElement)->[String]{[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute,kAXIdentifierAttribute].compactMap{get(e,$0) as? String}.filter{!$0.isEmpty}}
func frame(_ e:AXUIElement)->CGRect?{guard let p=get(e,kAXPositionAttribute),let s=get(e,kAXSizeAttribute) else{return nil};var origin=CGPoint.zero,size=CGSize.zero;AXValueGetValue(p as! AXValue,.cgPoint,&origin);AXValueGetValue(s as! AXValue,.cgSize,&size);return CGRect(origin:origin,size:size)}
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
func post(_ type:CGEventType,_ p:CGPoint){CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)}
// Moves the pointer between press and release as a trackpad press or a drag does.
func gesture(from a:CGPoint,to b:CGPoint){
    post(.mouseMoved,a);usleep(80_000);post(.leftMouseDown,a);usleep(60_000)
    let steps=max(1,Int(hypot(b.x-a.x,b.y-a.y)/4));for k in 1...steps{let t=CGFloat(k)/CGFloat(steps);post(.leftMouseDragged,CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t));usleep(12_000)}
    post(.leftMouseUp,b);usleep(150_000)
}
// Scrolls with the wheel, as a person does, until the element sits inside its window below the toolbar.
func reveal(_ e:AXUIElement?){guard let e=e,let w=get(e,kAXWindowAttribute),let wf=frame(w as! AXUIElement) else{return};let visible=wf.insetBy(dx:0,dy:40).offsetBy(dx:0,dy:20)
    for _ in 0..<60{guard let f=frame(e),!visible.contains(CGPoint(x:f.midX,y:f.midY)) else{return};let p=CGPoint(x:f.midX,y:wf.midY);post(.mouseMoved,p)
        let wheel=CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:1,wheel1:f.midY>wf.midY ? -2:2,wheel2:0,wheel3:0);wheel?.location=p;wheel?.post(tap:.cghidEventTap);usleep(60_000)}}
func click(_ p:CGPoint){post(.mouseMoved,p);usleep(80_000);post(.leftMouseDown,p);usleep(70_000);post(.leftMouseUp,p);usleep(150_000)}
let action=CommandLine.arguments.count>2 ? CommandLine.arguments[2]:""
let a=CommandLine.arguments.count>3 ? CommandLine.arguments[3]:"",b=CommandLine.arguments.count>4 ? CommandLine.arguments[4]:""
NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateAllWindows]);usleep(250_000)
switch action {
case "click":let e=element(a);reveal(e);click(center(e,a))
case "click-square":click(center(square(a),a))
// Press a square and drift by the given distance before releasing, as a slightly moving trackpad click does.
case "drift-square":let p=center(square(a),a);gesture(from:p,to:CGPoint(x:p.x+(Double(b) ?? 0),y:p.y+(Double(b) ?? 0)*0.3))
case "drag-square":gesture(from:center(square(a),a),to:center(square(b),b))
case "label":guard let e=square(a) else{fputs("Not found: \(a)\n",stderr);exit(2)};print(names(e).first ?? "")
case "value":guard let e=element(a) else{fputs("Not found: \(a)\n",stderr);exit(2)};print(get(e,kAXValueAttribute).map{"\($0)"} ?? "")
case "menu-open":print(find(app){role,n in role=="AXMenuItem" && n.contains(a)}.flatMap(frame).map{$0.width>0 && $0.height>0} ?? false)
// Opens a menu-bar menu and chooses an item, both with the pointer.
case "menu":let top=(get(app,kAXMenuBarAttribute)).flatMap{bar in find(bar as! AXUIElement){role,n in role=="AXMenuBarItem" && n.contains(a)}};click(center(top,a));usleep(250_000);click(center(top.flatMap{find($0){role,n in role=="AXMenuItem" && n.contains(b)}},b))
case "escape":CGEvent(keyboardEventSource:source,virtualKey:53,keyDown:true)?.post(tap:.cghidEventTap);CGEvent(keyboardEventSource:source,virtualKey:53,keyDown:false)?.post(tap:.cghidEventTap);usleep(150_000)
default:fputs("Unknown action\n",stderr);exit(1)
}
