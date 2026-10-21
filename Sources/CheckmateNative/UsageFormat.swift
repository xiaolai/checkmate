import Foundation

/// Usage in plain numbers (V-16): grouped token counts, whole minutes and money to the cent. Counted words take their
/// plural forms from the String Catalog; `number` groups a bare count the way US English does.
enum UsageFormat {
    private static let locale=Locale(identifier:"en_US")
    static func number(_ value:Int64)->String {value.formatted(.number.locale(locale))}
    static func tokens(_ value:Int64)->String {String(localized:"\(value) tokens",bundle:.checkmate,comment:"A count of tokens; the catalog holds its plural forms")}
    /// Rounded to the nearest minute; less than one is "under a minute".
    static func minutes(_ seconds:Double)->String {
        guard seconds>=60 else{return String(localized:"under a minute",bundle:.checkmate)}
        let minutes=Int64((seconds/60).rounded());return String(localized:"\(minutes) minutes",bundle:.checkmate,comment:"A count of whole minutes; the catalog holds its plural forms")
    }
    static func dollars(_ value:Double)->String {value>0 && value<0.01 ? String(localized:"less than $0.01",bundle:.checkmate,comment:"A cost below one cent"):String(format:"$%.2f",value)}
    static func credits(_ value:Double)->String {value>0 && value<0.01 ? String(localized:"less than 0.01",bundle:.checkmate,comment:"A credit amount below one hundredth"):String(format:"%.2f",value)}
    /// One activity's line: how many uses, then the tokens and time when they are known.
    static func summary(tokens:Int64?,seconds:Double?,uses:Int)->String {
        guard uses>0 else{return String(localized:"None",bundle:.checkmate)}
        return ([String(localized:"\(uses) uses",bundle:.checkmate,comment:"How many times an activity ran; the catalog holds its plural forms")]+[tokens.map(Self.tokens),seconds.map(minutes)].compactMap{$0}).joined(separator:" · ")
    }
}
