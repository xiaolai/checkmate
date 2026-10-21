import CheckmateAssets
/// Whole sentences read one after another ("Correct." then the reason). Each part is a whole sentence with its own
/// catalog entry; the joiner is translated too, since not every language puts a space between sentences.
public enum Sentences {
    public static func join(_ parts:[String])->String {
        parts.filter{!$0.isEmpty}.reduce(""){$0.isEmpty ? $1:String(localized:"\($0) \($1)",bundle:.checkmate,comment:"Two whole sentences, one after the other")}
    }
    public static func join(_ parts:String...)->String {join(parts)}
}
