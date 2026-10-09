import Foundation
let preferences=UserDefaults(suiteName:"ai.xiaolai.checkmate.native-prototype")!
var archive:[String:Any]=["format":"checkmate-spike-export","version":1]
if let fen=preferences.string(forKey:"fen"){archive["spikeFEN"]=fen}
archive["checkmate-settings-v1"]=["boardTheme":["Walnut":"wood","Sage":"green","Slate":"blue","Graphite":"neutral"][preferences.string(forKey:"theme") ?? "Walnut"] ?? "wood","skill":preferences.integer(forKey:"skill")]
try JSONSerialization.data(withJSONObject:archive,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
