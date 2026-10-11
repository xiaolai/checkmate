import CheckmateDomain
import CheckmateAssets
import Foundation
public func jsonObject<T:Encodable>(_ value:T)->Any {guard let data=try? JSONEncoder().encode(value),let object=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed) else{return NSNull()};return publicJSON(object)}
private func publicJSON(_ raw:Any)->Any {
    if let array=raw as? [Any]{return array.map(publicJSON)}
    guard var object=raw as? [String:Any] else{return raw}
    var nullable:[String]=[]
    if object["before"] != nil,object["after"] != nil,object["description"] != nil{nullable += ["promotion","capture","rookMove"]}
    if object["budgetMs"] != nil,object["lines"] != nil{nullable += ["bestMove"]}
    if object["fen"] != nil,object["explanation"] != nil,object["highlights"] != nil{nullable += ["san","uci","captured"]}
    if object["rootAnalysis"] != nil,object["comparison"] != nil{nullable += ["recommended","candidateAnalysis","candidateScore","lossCp"]}
    if object["basePosition"] != nil,object["displayFen"] != nil{nullable += ["candidate","evaluation","error"]}
    if object["summary"] != nil,object["status"] != nil{nullable += ["recommendation","analysis"]}
    for key in nullable where object[key]==nil{object[key]=NSNull()}
    for (key,value) in object{object[key]=publicJSON(value)}
    return object
}
