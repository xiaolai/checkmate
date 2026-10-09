// Standalone build-host helper for the native review scenario, run concurrently with scripts/test-review-ui.sh:
// 1. answers the scenario's numbered accessibility requests (rendered text/visibility, enabled state,
//    AXPress, selected sidebar row) from outside the app process;
// 2. selects the actual fixture row in the real Open panel and presses Open;
// 3. after normal termination, reads back the persisted review cursor and ideas.
import AppKit
import ApplicationServices
guard ProcessInfo.processInfo.hostName.lowercased().contains("build-host") || ProcessInfo.processInfo.hostName.lowercased().contains("build-host") else{fatalError("Run native UI helpers on build-host only")}
let directory=URL(fileURLWithPath:CommandLine.arguments[1]),marker=directory.appendingPathComponent("open-panel-ready.json"),resultURL=directory.appendingPathComponent("review-ui-results.json")
let isolatedBundle="ai.xiaolai.checkmate.native-review-automation"
func value(_ element:AXUIElement,_ attribute:String)->CFTypeRef?{var value:CFTypeRef?;AXUIElementCopyAttributeValue(element,attribute as CFString,&value);return value}
func names(_ element:AXUIElement)->[String]{[kAXValueAttribute,kAXTitleAttribute,kAXDescriptionAttribute].compactMap{value(element,$0) as? String}}
/// Depth-first search; `button` restricts matches to AXButton (titles such as "Open" also label other elements).
func find(_ element:AXUIElement,_ text:String,button:Bool=false,depth:Int=0,budget:inout Int)->AXUIElement? {
    budget-=1;if budget<0 || depth>45 {return nil}
    if (!button || value(element,kAXRoleAttribute) as? String==kAXButtonRole) && names(element).contains(text){return element}
    for child in value(element,kAXChildrenAttribute) as? [AXUIElement] ?? []{if let found=find(child,text,button:button,depth:depth+1,budget:&budget){return found}}
    return nil
}
func find(_ element:AXUIElement,_ text:String,button:Bool=false)->AXUIElement? {var budget=40000;return find(element,text,button:button,budget:&budget)}
func rect(_ element:AXUIElement)->CGRect? {
    guard let rawPosition=value(element,kAXPositionAttribute),let rawSize=value(element,kAXSizeAttribute) else{return nil}
    var point=CGPoint.zero,size=CGSize.zero;AXValueGetValue(rawPosition as! AXValue,.cgPoint,&point);AXValueGetValue(rawSize as! AXValue,.cgSize,&size);return CGRect(origin:point,size:size)
}
func isolatedApp(_ pid:Int)->AXUIElement {
    guard let app=NSRunningApplication(processIdentifier:pid_t(pid)),app.bundleIdentifier==isolatedBundle else{fatalError("Request is not from the isolated review automation app")}
    let element=AXUIElementCreateApplication(pid_t(pid));AXUIElementSetMessagingTimeout(element,3);return element
}
/// One check; "passed" is decided here so the app cannot certify its own rendering.
func run(_ check:[String:Any],in app:AXUIElement)->[String:Any] {
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
        let status=AXUIElementPerformAction(button,kAXPressAction as CFString).rawValue;result["found"]=true;result["axError"]=Int(status);result["passed"]=status==0
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
    let ax=isolatedApp(pid);Thread.sleep(forTimeInterval:0.4)
    guard var row=find(ax,URL(fileURLWithPath:path).lastPathComponent) else{fatalError("Known fixture row absent from actual panel")}
    for _ in 0..<8 {if value(row,kAXRoleAttribute) as? String==kAXRowRole{break};guard let parent=value(row,kAXParentAttribute) else{break};row=parent as! AXUIElement}
    print("Row role",value(row,kAXRoleAttribute) ?? "")
    print("Row selection",AXUIElementSetAttributeValue(row,kAXSelectedAttribute as CFString,kCFBooleanTrue).rawValue)
    if let parent=value(row,kAXParentAttribute){print("Container selection",AXUIElementSetAttributeValue(parent as! AXUIElement,kAXSelectedRowsAttribute as CFString,[row] as CFArray).rawValue)}
    Thread.sleep(forTimeInterval:0.3)
    guard let open=find(ax,"Open",button:true) else{fatalError("Open control absent")}
    print("Open action",AXUIElementPerformAction(open,kAXPressAction as CFString).rawValue)
    print("Selected actual fixture row and pressed Open")
}

var nextRequest=1,panelDone=false,pid:Int?
let deadline=Date().addingTimeInterval(420)
while Date()<deadline {
    if FileManager.default.fileExists(atPath:resultURL.path){break}
    if !panelDone,FileManager.default.fileExists(atPath:marker.path){openPanelPhase();panelDone=true;continue}
    let request=directory.appendingPathComponent("ax-request-\(nextRequest).json")
    if let data=try? Data(contentsOf:request),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let owner=object["pid"] as? Int,let checks=object["checks"] as? [[String:Any]] {
        pid=owner;let app=isolatedApp(owner);let results=checks.map{run($0,in:app)}
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
