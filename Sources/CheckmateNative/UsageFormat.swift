import Foundation

/// Usage in plain numbers (V-16): grouped token counts, whole minutes and money to the cent. The app's text is US
/// English, so the grouping is too.
enum UsageFormat {
    private static let locale=Locale(identifier:"en_US")
    static func number(_ value:Int64)->String {value.formatted(.number.locale(locale))}
    static func tokens(_ value:Int64)->String {value==1 ? "\(number(value)) token":"\(number(value)) tokens"}
    /// Rounded to the nearest minute; less than one is "under a minute".
    static func minutes(_ seconds:Double)->String {
        guard seconds>=60 else{return "under a minute"}
        let minutes=Int64((seconds/60).rounded());return minutes==1 ? "\(number(minutes)) minute":"\(number(minutes)) minutes"
    }
    static func dollars(_ value:Double)->String {value>0 && value<0.01 ? "less than $0.01":String(format:"$%.2f",value)}
    static func credits(_ value:Double)->String {value>0 && value<0.01 ? "less than 0.01":String(format:"%.2f",value)}
    /// One activity's line: how many uses, then the tokens and time when they are known.
    static func summary(tokens:Int64?,seconds:Double?,uses:Int)->String {
        guard uses>0 else{return "None"}
        return ([uses==1 ? "\(number(Int64(uses))) use":"\(number(Int64(uses))) uses"]+[tokens.map(Self.tokens),seconds.map(minutes)].compactMap{$0}).joined(separator:" · ")
    }
}
