import AppKit
import WebKit
let app=NSApplication.shared
let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
let web=WKWebView(frame:.zero,configuration:configuration)
final class Delegate:NSObject,WKNavigationDelegate {
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){let fixture="localStorage.setItem('checkmate-practice-pgn','1. e4 e5');localStorage.setItem('checkmate-settings-v1',JSON.stringify({boardTheme:'blue',voiceLanguage:'ja'}));localStorage.setItem('unrelated-secret','excluded');"
        webView.evaluateJavaScript(fixture){_,error in if let error=error{fputs("Fixture failed: \(error)\n",stderr);exit(1)};let script=try! String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8);webView.evaluateJavaScript(script){value,error in guard error==nil,let result=value as? String,!result.contains("unrelated-secret") else{exit(1)};try! Data(result.utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print("Isolated WebKit export passed");exit(0)}}}
}
let delegate=Delegate();web.navigationDelegate=delegate
web.loadHTMLString("<html>Legacy storage fixture</html>",baseURL:URL(string:"http://127.0.0.1:17371"))
DispatchQueue.main.asyncAfter(deadline:.now()+10){exit(1)}
app.run()
