import SwiftUI
import CheckmateCore

struct RelationshipContent:View {
    @ObservedObject var relationships:RelationshipController
    let label:String,inspect:(RelationshipMode)->Void
    /// The caption every relation shares, said once for the list; nil when there is one relation or the captions differ.
    static func sharedCaption(_ captions:[String])->String? {
        guard captions.count>1,let first=captions.first,captions.allSatisfy({$0==first}) else{return nil};return first
    }
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text(label).sectionHeading()
            HStack {ForEach(RelationshipMode.allCases,id:\.self){mode in
                Toggle(mode.title,isOn:Binding(get:{relationships.mode==mode},set:{value in if value != (relationships.mode==mode){inspect(mode)}})).toggleStyle(.button).help("\(mode.title) · \(mode.shortcut) while the board has focus").accessibilityValue(relationships.mode==mode ? String(localized:"On",bundle:.checkmate,comment:"State of a toggle"):String(localized:"Off",bundle:.checkmate,comment:"State of a toggle"))
            }}
            // The selected toggle above names the mode, so the report has no heading of its own.
            if let report=relationships.report {
                if report.relations.isEmpty{Text(report.emptyMessage)}
                let captions=report.relations.map{$0.explanation(mode:report.mode,legalContext:report.legalContext,king:report.piece=="k")},shared=Self.sharedCaption(captions)
                if let shared{Text(shared).font(.callout)}
                ForEach(Array(report.relations.enumerated()),id:\.element.square){index,relation in
                    VStack(alignment:.leading,spacing:Metrics.smallGap){
                        Label(relation.label,systemImage:(relation.limited ? AppSymbol.limited:.protection).rawValue).font(.headline)
                        if shared==nil{Text(captions[index]).font(.callout)}
                    }.padding(.vertical,Metrics.smallGap)
                }
                Text(report.note).font(.caption).foregroundStyle(.secondary)
                Text("P: protection · A: attacks · Esc: dismiss").font(.caption).foregroundStyle(.secondary)
            }
            if let error=relationships.error{Text(error).foregroundStyle(.secondary)}
        }.textSelection(.enabled)
    }
}
