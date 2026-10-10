import SwiftUI
import CheckmateCore

struct RelationshipContent:View {
    @ObservedObject var relationships:RelationshipController
    let label:String,inspect:(RelationshipMode)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text(label).font(.headline)
            HStack {ForEach(RelationshipMode.allCases,id:\.self){mode in
                Toggle(mode.title,isOn:Binding(get:{relationships.mode==mode},set:{value in if value != (relationships.mode==mode){inspect(mode)}})).toggleStyle(.button).help("\(mode.title) · \(mode.shortcut) while the board has focus").accessibilityValue(relationships.mode==mode ? "On":"Off")
            }}
            if let report=relationships.report {
                Text(report.mode.title).font(.title2.bold())
                if report.relations.isEmpty{Text(report.emptyMessage)}
                ForEach(report.relations,id:\.square){relation in
                    VStack(alignment:.leading,spacing:Metrics.smallGap){
                        Label(relation.label,systemImage:relation.limited ? "exclamationmark.circle":"link").font(.headline)
                        Text(relation.explanation(mode:report.mode,legalContext:report.legalContext,king:report.piece=="k")).font(.callout)
                    }.padding(.vertical,Metrics.smallGap)
                }
                Text(report.note).font(.caption).foregroundStyle(.secondary)
                Text("P: protection · A: attacks · Esc: dismiss").font(.caption).foregroundStyle(.secondary)
            }
            if let error=relationships.error{Text(error).foregroundStyle(.secondary)}
        }.textSelection(.enabled)
    }
}
