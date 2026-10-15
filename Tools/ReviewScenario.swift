// Standalone test-host helper for the native review scenario, run concurrently with scripts/test-review-ui.sh:
// 1. answers the scenario's numbered accessibility requests (rendered text/visibility, enabled state,
//    real pointer clicks, selected sidebar row) from outside the app process;
// 2. selects the actual fixture row in the real Open panel and presses Open;
// 3. after normal termination, reads back the persisted review cursor and ideas.
import AppKit
import ApplicationServices
// The same test hosts as scripts/test_host.py; scripts/test-run-gates.py checks the two lists agree.
let testHosts=["test-host"]
guard testHosts.contains(where:ProcessInfo.processInfo.hostName.lowercased().contains) else{fatalError("Run native UI helpers on a test host only (\(testHosts.joined(separator:", ")))")}
let directory=URL(fileURLWithPath:CommandLine.arguments[1]),marker=directory.appendingPathComponent("open-panel-ready.json"),resultURL=directory.appendingPathComponent("review-ui-results.json")
let isolatedBundle="ai.xiaolai.checkmate.native-review-automation"
func value(_ element:AXUIElement,_ attribute:String)->CFTypeRef?{var value:CFTypeRef?;AXUIElementCopyAttributeValue(element,attribute as CFString,&value);return value}
func names(_ element:AXUIElement)->[String]{[kAXValueAttribute,kAXTitleAttribute,kAXDescriptionAttribute].compactMap{value(element,$0) as? String}}
/// Depth-first search; `button` restricts matches to AXButton (titles such as "Open" also label other elements).
func find(_ element:AXUIElement,_ text:String,button:Bool=false,roles:Set<String>?=nil,depth:Int=0,budget:inout Int)->AXUIElement? {
    budget-=1;if budget<0 || depth>45 {return nil}
    let role=value(element,kAXRoleAttribute) as? String ?? ""
    if (!button || role==kAXButtonRole) && roles.map({$0.contains(role)}) != false && names(element).contains(text){return element}
    for child in value(element,kAXChildrenAttribute) as? [AXUIElement] ?? []{if let found=find(child,text,button:button,roles:roles,depth:depth+1,budget:&budget){return found}}
    return nil
}
func find(_ element:AXUIElement,_ text:String,button:Bool=false,roles:Set<String>?=nil)->AXUIElement? {var budget=40000;return find(element,text,button:button,roles:roles,budget:&budget)}
/// A file's entry in a panel, in any of its views: never the panel window, whose title can repeat the file name.
let fileEntryRoles:Set<String>=[kAXStaticTextRole,kAXTextFieldRole,kAXCellRole,kAXRowRole,kAXImageRole]
let keySource=CGEventSource(stateID:.hidSystemState)
func key(_ code:CGKeyCode,flags:CGEventFlags=[]){for down in [true,false]{let event=CGEvent(keyboardEventSource:keySource,virtualKey:code,keyDown:down)!;event.flags=down ? flags:[];event.post(tap:.cghidEventTap)};usleep(150_000)}
func type(_ text:String){for character in text{let units=Array(String(character).utf16);for down in [true,false]{let event=CGEvent(keyboardEventSource:keySource,virtualKey:0,keyDown:down)!;units.withUnsafeBufferPointer{if let address=$0.baseAddress{event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:address)}};event.post(tap:.cghidEventTap)};usleep(8_000)};usleep(200_000)}
func rect(_ element:AXUIElement)->CGRect? {
    guard let rawPosition=value(element,kAXPositionAttribute),let rawSize=value(element,kAXSizeAttribute) else{return nil}
    var point=CGPoint.zero,size=CGSize.zero;AXValueGetValue(rawPosition as! AXValue,.cgPoint,&point);AXValueGetValue(rawSize as! AXValue,.cgSize,&size);return CGRect(origin:point,size:size)
}
/// Scrolls with the wheel, as a person does, until the element's centre is inside its window below the toolbar.
func reveal(_ element:AXUIElement)->Bool {
    // Elements in system panels may not report their window; one with an on-screen frame is already visible.
    guard let window=value(element,kAXWindowAttribute),let windowFrame=rect(window as! AXUIElement) else{return rect(element).map{$0.width>0 && $0.height>0} ?? false}
    let visible=windowFrame.insetBy(dx:0,dy:40).offsetBy(dx:0,dy:20),source=CGEventSource(stateID:.hidSystemState)
    for _ in 0..<80 {
        guard let box=rect(element) else{return false};if visible.contains(CGPoint(x:box.midX,y:box.midY)){return true}
        let point=CGPoint(x:min(max(box.midX,visible.minX+4),visible.maxX-4),y:windowFrame.midY)
        CGEvent(mouseEventSource:source,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
        let wheel=CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:1,wheel1:box.midY>windowFrame.midY ? -2:2,wheel2:0,wheel3:0);wheel?.location=point;wheel?.post(tap:.cghidEventTap);usleep(60_000)
    }
    return false
}
func owner(at point:CGPoint)->pid_t?{var hit:AXUIElement?;guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,let hit else{return nil};var owner:pid_t=0;AXUIElementGetPid(hit,&owner);return owner}
/// A real pointer click at the element's centre: posted HID events go through hit-testing, unlike AXPress.
func click(_ element:AXUIElement,pid:Int)->Bool {
    // A sheet's buttons exist before the sheet has animated on screen; wait for a real frame to click.
    var frame:CGRect?;for _ in 0..<30{if let box=rect(element),box.width>0,box.height>0{frame=box;break};Thread.sleep(forTimeInterval:0.1)}
    guard frame != nil,reveal(element),let box=rect(element) else{return false}
    let point=CGPoint(x:box.midX,y:box.midY),source=CGEventSource(stateID:.hidSystemState)
    // The click must land on the app under test: another app's window or a system prompt would take it silently.
    var covering:pid_t?
    for _ in 0..<3{NSRunningApplication(processIdentifier:pid_t(pid))?.activate(options:[]);Thread.sleep(forTimeInterval:0.25);covering=owner(at:point);if covering==nil || covering==pid_t(pid){break}}
    if let covering,covering != pid_t(pid){print("Click at \(point) is covered by \(NSRunningApplication(processIdentifier:covering)?.localizedName ?? "pid \(covering)")");return false}
    for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);usleep(60_000)}
    return true
}
func isolatedApp(_ pid:Int)->AXUIElement {
    guard let app=NSRunningApplication(processIdentifier:pid_t(pid)),app.bundleIdentifier==isolatedBundle else{fatalError("Request is not from the isolated review automation app")}
    let element=AXUIElementCreateApplication(pid_t(pid));AXUIElementSetMessagingTimeout(element,3);return element
}
/// One check; "passed" is decided here so the app cannot certify its own rendering.
func run(_ check:[String:Any],in app:AXUIElement,pid:Int)->[String:Any] {
    var result=check;let kind=check["kind"] as? String ?? ""
    switch kind {
    case "text":
        let text=check["value"] as? String ?? ""
        guard !text.isEmpty,let element=find(app,text) else{result["found"]=false;result["passed"]=false;return result}
        let frame=rect(element),window=(value(element,kAXWindowAttribute)).map{rect($0 as! AXUIElement)} ?? nil
        let visible=frame.map{box in box.width>0 && box.height>0 && (window.map{$0.intersects(box)} ?? false)} ?? false
        result["found"]=true;result["role"]=value(element,kAXRoleAttribute) as? String ?? "";result["visible"]=visible;result["y"]=Double(frame?.minY ?? -1);result["passed"]=visible
    case "enabled":
        let title=check["title"] as? String ?? "",expected=check["expected"] as? Bool ?? true
        guard let button=find(app,title,button:true) else{result["found"]=false;result["passed"]=false;return result}
        let enabled=value(button,kAXEnabledAttribute) as? Bool;result["found"]=true;result["enabled"]=enabled as Any? ?? NSNull();result["passed"]=enabled==expected
    case "press":
        let title=check["title"] as? String ?? ""
        guard let button=find(app,title,button:true) else{result["found"]=false;result["passed"]=false;return result}
        let clicked=click(button,pid:pid);result["found"]=true;result["pointerClick"]=clicked;result["passed"]=clicked
    case "selectedRow":
        let text=check["value"] as? String ?? ""
        guard var row=find(app,text) else{result["found"]=false;result["passed"]=false;return result}
        for _ in 0..<8 {if value(row,kAXRoleAttribute) as? String==kAXRowRole{break};guard let parent=value(row,kAXParentAttribute) else{break};row=parent as! AXUIElement}
        let selected=value(row,kAXSelectedAttribute) as? Bool;result["found"]=value(row,kAXRoleAttribute) as? String==kAXRowRole;result["selected"]=selected as Any? ?? NSNull();result["passed"]=selected==true
    default:result["passed"]=false;result["error"]="unknown check"
    }
    return result
}
func openPanelPhase(){
    guard let data=try? Data(contentsOf:marker),let payload=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let pid=payload["pid"] as? Int,let path=payload["path"] as? String,let app=NSRunningApplication(processIdentifier:pid_t(pid)),app.bundleIdentifier==isolatedBundle else{fatalError("Missing isolated panel marker")}
    app.activate(options:[.activateAllWindows]);Thread.sleep(forTimeInterval:0.4)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid_t(pid) else{fatalError("Isolated app is not foreground")}
    // The panel may open in a remembered folder and view on a given machine, so choose the fixture as a person would:
    // Go to Folder with its path selects it in any view. A visible entry is clicked too, when the view shows one.
    let ax=isolatedApp(pid),name=URL(fileURLWithPath:path).lastPathComponent
    guard find(ax,"Open",button:true) != nil else{fatalError("Open panel absent")}
    key(5,flags:[.maskCommand,.maskShift]);usleep(300_000);type(path);key(36);usleep(400_000)
    let deadline=Date().addingTimeInterval(3)
    var found=find(ax,name,roles:fileEntryRoles);while found==nil,Date()<deadline{Thread.sleep(forTimeInterval:0.1);found=find(ax,name,roles:fileEntryRoles)}
    if found==nil{let shot=Process();shot.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");shot.arguments=["-x",directory.appendingPathComponent("open-panel-missing-row.png").path];try? shot.run();shot.waitUntilExit()}
    guard let entry=found else{fatalError("Known fixture row absent from actual panel")}
    // List view wraps an entry in a row; column view does not. Click the row when there is one, otherwise the entry.
    var row=entry,ancestor:AXUIElement?=entry
    for _ in 0..<8 {guard let current=ancestor else{break};if value(current,kAXRoleAttribute) as? String==kAXRowRole{row=current;break};ancestor=value(current,kAXParentAttribute).map{$0 as! AXUIElement}}
    FileHandle.standardError.write(Data("Fixture entry role \(value(row,kAXRoleAttribute) ?? "" as CFString)\n".utf8))
    guard let open=find(ax,"Open",button:true) else{fatalError("Open control absent")}
    // The Open panel is system UI, not the app under test: click it like a person when it reports frames, otherwise
    // select through accessibility, and say which path ran.
    let selectedByPath=value(open,kAXEnabledAttribute) as? Bool==true
    if selectedByPath{FileHandle.standardError.write(Data("Go to Folder chose the fixture\n".utf8))}
    else if click(row,pid:pid){FileHandle.standardError.write(Data("Clicked the fixture row with the pointer\n".utf8))}else{print("Row selection via accessibility",AXUIElementSetAttributeValue(row,kAXSelectedAttribute as CFString,kCFBooleanTrue).rawValue);if let parent=value(row,kAXParentAttribute){_=AXUIElementSetAttributeValue(parent as! AXUIElement,kAXSelectedRowsAttribute as CFString,[row] as CFArray)}}
    // A chosen file is what enables Open, in every view of the panel.
    let chosen=Date().addingTimeInterval(2);while value(open,kAXEnabledAttribute) as? Bool != true,Date()<chosen{Thread.sleep(forTimeInterval:0.1)}
    guard value(open,kAXEnabledAttribute) as? Bool==true else{
        let shot=Process();shot.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");shot.arguments=["-x",directory.appendingPathComponent("open-panel-unselected.png").path];try? shot.run();shot.waitUntilExit()
        fatalError("The fixture file is not chosen: Open stays disabled (clicked \(value(row,kAXRoleAttribute) ?? "none" as CFString) at \(rect(row).map{"\($0)"} ?? "no frame"))")}
    if click(open,pid:pid){print("Clicked Open with the pointer")}else{print("Open via accessibility",AXUIElementPerformAction(open,kAXPressAction as CFString).rawValue)}
}

var nextRequest=1,panelDone=false,pid:Int?
let deadline=Date().addingTimeInterval(420)
while Date()<deadline {
    if FileManager.default.fileExists(atPath:resultURL.path){break}
    if !panelDone,FileManager.default.fileExists(atPath:marker.path){openPanelPhase();panelDone=true;continue}
    let request=directory.appendingPathComponent("ax-request-\(nextRequest).json")
    if let data=try? Data(contentsOf:request),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let owner=object["pid"] as? Int,let checks=object["checks"] as? [[String:Any]] {
        pid=owner;let app=isolatedApp(owner);let results=checks.map{run($0,in:app,pid:owner)}
        let verified=results.allSatisfy{$0["passed"] as? Bool==true};print("AX request \(nextRequest) \(object["name"] as? String ?? "") passed=\(verified)")
        try JSONSerialization.data(withJSONObject:["name":object["name"] ?? "","results":results,"passed":verified],options:.sortedKeys).write(to:directory.appendingPathComponent("ax-result-\(nextRequest).json"),options:.atomic)
        nextRequest+=1;continue
    }
    Thread.sleep(forTimeInterval:0.1)
}
guard panelDone else{fatalError("Open panel phase never ran")}

var result:[String:Any]?
for _ in 0..<900{if let data=try? Data(contentsOf:resultURL),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{result=object;break};Thread.sleep(forTimeInterval:0.1)}
let appPID=(try? JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as? [String:Any])?["pid"] as? Int ?? pid ?? 0
for _ in 0..<100{if NSRunningApplication(processIdentifier:pid_t(appPID))==nil{break};Thread.sleep(forTimeInterval:0.1)}
guard NSRunningApplication(processIdentifier:pid_t(appPID))==nil,let result=result,let documentPath=result["reviewDocumentFile"] as? String,let expected=result["expectedPersistedCursor"] as? Int else{fatalError("No terminated scenario persistence result")}
let documentURL=URL(fileURLWithPath:documentPath),record=try JSONSerialization.jsonObject(with:Data(contentsOf:documentURL)) as! [String:Any]
var cursor=record["cursor"] as! Int
let sidecar=documentURL.deletingPathExtension().appendingPathExtension("cursor.json")
if let data=try? Data(contentsOf:sidecar),let metadata=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let date=metadata["updatedAt"] as? Double, date >= (record["updatedAt"] as? Double ?? 0){cursor=metadata["cursor"] as! Int}
guard cursor==expected,(record["branches"] as? [Any])?.count==result["expectedSavedIdeas"] as? Int else{fatalError("Normal termination lost latest cursor or ideas")}
try JSONSerialization.data(withJSONObject:["passed":true,"cursor":cursor,"normalTermination":true,"accessibilityRequestsAnswered":nextRequest-1]).write(to:directory.appendingPathComponent("shutdown-persistence-result.json"))
print("Normal termination preserves latest review cursor and ideas; answered \(nextRequest-1) accessibility requests")
