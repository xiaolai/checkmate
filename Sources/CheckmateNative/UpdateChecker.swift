import Foundation
import CheckmateCore
/// Check for Updates… (V-19): asks GitHub for the latest release, on request, or at launch only when the learner turned
/// that on. The fetch is injected, so tests never reach the network.
struct UpdateChecker:Sendable {
    struct Release:Equatable,Sendable {let version:String,page:URL}
    enum Outcome:Equatable,Sendable {case available(Release),current(String),failed}
    static let latest=URL(string:"https://api.github.com/repos/xiaolai/checkmate/releases/latest")!
    /// Only a release page of this project is ever opened from the answer.
    static let releasePages="https://github.com/xiaolai/checkmate/releases/"
    var fetch:@Sendable (URL) async throws -> Data
    /// The network, outside automation; a silent run refuses before any request is made.
    static let live=UpdateChecker{url in
        guard !NativePolicy.silent else{throw URLError(.cancelled)}
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15);request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        let (data,response)=try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode==200,data.count<=1_000_000 else{throw URLError(.badServerResponse)};return data
    }
    /// The release's version (its tag without a leading "v") and page; nil for anything else.
    static func parse(_ data:Data)->Release? {
        guard let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let tag=object["tag_name"] as? String,let page=(object["html_url"] as? String).flatMap(URL.init(string:)),page.absoluteString.hasPrefix(releasePages) else{return nil}
        let version=tag.hasPrefix("v") ? String(tag.dropFirst()):tag
        guard !version.isEmpty,version.count<=32,version.allSatisfy({$0.isNumber || $0=="."}) else{return nil};return Release(version:version,page:page)
    }
    /// Numeric, part by part; a missing part counts as 0, so 2.0 is not newer than 2.0.0.
    static func newer(_ candidate:String,than current:String)->Bool {
        func parts(_ v:String)->[Int] {(v.hasPrefix("v") ? String(v.dropFirst()):v).split(separator:".").map{Int($0) ?? 0}}
        let a=parts(candidate),b=parts(current)
        for i in 0..<max(a.count,b.count) {let x=i<a.count ? a[i]:0,y=i<b.count ? b[i]:0;if x != y{return x>y}};return false
    }
    func check(current:String) async -> Outcome {
        guard let data=try? await fetch(Self.latest),let release=Self.parse(data) else{return .failed}
        return Self.newer(release.version,than:current) ? .available(release):.current(current)
    }
}
