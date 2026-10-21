import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CheckmateCore

struct UsageSettingsPane:View {
    @ObservedObject var ledger:UsageLedger
    @ObservedObject var controller:LessonLanguageController
    @State private var range=UsageTimeRange.today
    @State private var error:String?
    private var records:[UsageRecord]{ledger.records(in:range).sorted{$0.startedAt>$1.startedAt}}
    private func title(_ activity:UsageActivity)->String {switch activity{case .translation:return String(localized:"Lesson translation",bundle:.checkmate);case .lessonRecording:return String(localized:"Lesson recording",bundle:.checkmate);case .voiceCoach:return String(localized:"Voice coach",bundle:.checkmate);case .inputTranscription:return String(localized:"Input transcription",bundle:.checkmate)}}
    private func count(_ value:Int64?)->String{value.map(UsageFormat.number) ?? String(localized:"Unknown",bundle:.checkmate)}
    var body:some View {
        Section("Checkmate activity") {
            Picker("Time range",selection:$range){Text("Today").tag(UsageTimeRange.today);Text("This month").tag(UsageTimeRange.thisMonth);Text("All retained").tag(UsageTimeRange.all)}.accessibilityIdentifier("usage-time-range")
            if let first=ledger.records.map(\.startedAt).min(){Text("Usage recorded from \(first.formatted(date:.abbreviated,time:.shortened)).").font(.caption).foregroundStyle(.secondary)}
            Text("History retains up to 365 days and 10,000 operations. Missing counters are unknown. Token activity does not establish your subscription bill.").font(.caption).foregroundStyle(.secondary)
            ForEach(UsageActivity.allCases,id:\.self){activity in
                let group=records.filter{$0.activity==activity}
                let known=group.compactMap{$0.tokens?.total}
                let durations=group.compactMap(\.durationSeconds)
                // V-16: one plain line per activity; the counts behind it are under Breakdown.
                VStack(alignment:.leading) {
                    LabeledContent(title(activity),value:UsageFormat.summary(tokens:known.isEmpty ? nil:known.reduce(0,+),seconds:durations.isEmpty ? nil:durations.reduce(0,+),uses:group.count))
                    if !group.isEmpty {
                        DisclosureGroup("Breakdown") {
                            Text("\(group.count) operations · \(Set(group.map(\.sessionID)).count) sessions").font(.caption).foregroundStyle(.secondary)
                            Text(known.isEmpty ? String(localized:"Tokens not reported",bundle:.checkmate):String(localized:"\(UsageFormat.tokens(known.reduce(0,+))) reported · \(group.count-known.count) not reported",bundle:.checkmate,comment:"Tokens reported, then how many operations reported none")).font(.caption).foregroundStyle(.secondary)
                            Text(durations.isEmpty ? String(localized:"Time not reported",bundle:.checkmate):String(localized:"\(UsageFormat.minutes(durations.reduce(0,+))) reported · \(group.count-durations.count) not reported",bundle:.checkmate,comment:"Time reported, then how many operations reported none")).font(.caption).foregroundStyle(.secondary)
                            let narrated=group.compactMap(\.narration)
                            if !narrated.isEmpty{Text("Narrated segments: \(narrated.filter{$0 == .verified}.count) heard as written · \(narrated.filter{$0 == .unverified}.count) shown as text instead · \(narrated.filter{$0 == .interrupted}.count) stopped").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("usage-narration-outcomes")}
                        }
                    }
                }
            }
            let totals=ledger.totals(in:range)
            Text("\(totals.knownRecords) operations with reported counters · \(totals.unknownRecords) unknown · \(totals.incompleteRecords) incomplete").font(.caption).foregroundStyle(.secondary)
            HStack{Button("Export JSON…"){export()}.disabled(ledger.unavailable).accessibilityIdentifier("usage-export");Button("Clear History…",role:.destructive){clear()}.disabled(controller.busy).accessibilityIdentifier("usage-clear")}
            if let problem=error ?? ledger.storageError{Text(problem).foregroundStyle(.secondary)}
        }
        Section("Account status") {
            Text(controller.accountStatus).textSelection(.enabled).accessibilityIdentifier("usage-account-status")
            // Account status has its own request, so it stays available while a lesson job spends credits.
            Button("Refresh Account Status"){controller.refreshAccount()}
            Text("Account limits and available credits cover your account. Voice subscription quota attribution is unknown unless the provider reports it.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Recent operations") {
            if records.isEmpty{Text("No recorded Checkmate activity in this time range.").foregroundStyle(.secondary)}
            ForEach(Array(records.prefix(100))){record in
                DisclosureGroup {
                    LabeledContent("Model",value:record.model ?? String(localized:"Unknown",bundle:.checkmate))
                    LabeledContent("Input tokens",value:count(record.tokens?.input))
                    LabeledContent("Output tokens",value:count(record.tokens?.output))
                    LabeledContent("Total tokens",value:count(record.tokens?.total))
                    LabeledContent("Cached input (subset)",value:count(record.tokens?.cachedInput))
                    LabeledContent("Cached text input (subset)",value:count(record.tokens?.cachedText))
                    LabeledContent("Cached audio input (subset)",value:count(record.tokens?.cachedAudio))
                    LabeledContent("Reasoning (subset)",value:count(record.tokens?.reasoning))
                    LabeledContent("Input text tokens",value:count(record.tokens?.inputText))
                    LabeledContent("Input audio tokens",value:count(record.tokens?.inputAudio))
                    LabeledContent("Output text tokens",value:count(record.tokens?.outputText))
                    LabeledContent("Output audio tokens",value:count(record.tokens?.outputAudio))
                    if let credits=record.estimatedCredits{LabeledContent("Provider credit estimate",value:UsageFormat.credits(credits))}
                    if let usd=record.estimatedUSD{LabeledContent("Provider USD estimate",value:UsageFormat.dollars(usd))}
                    if record.estimatedCredits != nil || record.estimatedUSD != nil{Text("Provider estimates are not actual charges.").font(.caption).foregroundStyle(.secondary)}
                    if let locale=record.locale{LabeledContent("Language",value:locale)}
                    if let voice=record.voice{LabeledContent("Voice",value:voice.capitalized)}
                    if let outcome=record.narration{LabeledContent("Narration",value:outcome == .verified ? String(localized:"Heard as written",bundle:.checkmate):outcome == .unverified ? String(localized:"Shown as text instead",bundle:.checkmate):String(localized:"Stopped",bundle:.checkmate))}
                    if let duration=record.durationSeconds{LabeledContent("Duration",value:Duration.seconds(duration).formatted(.units(allowed:[.seconds],width:.wide,fractionalPart:.show(length:1))))}
                    Text(record.startedAt.formatted(date:.abbreviated,time:.standard)).font(.caption)
                } label:{Text("\(title(record.activity)) · \(record.status.rawValue.capitalized)")}
            }
            if records.count>100{Text("Showing the most recent 100 operations. Export includes all retained history.").font(.caption).foregroundStyle(.secondary)}
        }
    }
    private func export(){
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Checkmate-usage.json"
        panel.begin{response in guard response == .OK,let url=panel.url else{return};Task{do{try? await ledger.flush();try ledger.exportJSON().write(to:url,options:.atomic);error=nil}catch{self.error=userFacingMessage(error,fallback:String(localized:"Usage history could not be exported. Choose another location.",bundle:.checkmate))}}}
    }
    private func clear(){
        let alert=NSAlert.destructive(String(localized:"Clear usage history?",bundle:.checkmate),ledger.unavailable ? String(localized:"The unreadable history file is kept, and a new history starts with this session’s activity. Your lessons, recordings and progress are kept.",bundle:.checkmate):String(localized:"This removes completed Checkmate usage history. Activity still running remains recorded. Your lessons, recordings and progress are kept.",bundle:.checkmate),action:String(localized:"Clear History",bundle:.checkmate))
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        Task{do{try ledger.clear();try await ledger.flush();error=nil}catch{self.error=String(localized:"Usage history could not be cleared.",bundle:.checkmate)}}
    }
}
