import Foundation
/// Counted text. Each form is a whole format string with one `%d`, so a translation replaces the sentence and never
/// a suffix glued to an English stem (D-13).
public enum Plural {
    /// Further arguments follow the count; a form that names them uses positional specifiers (`%1$d`, `%2$@`).
    public static func count(_ n:Int,one:String,other:String,_ arguments:CVarArg...)->String {String(format:n==1 ? one:other,arguments:[n]+arguments)}
    /// A list read as a sentence ("a, b and c"), joined by the system rather than by English separators.
    public static func list(_ items:[String])->String {ListFormatter.localizedString(byJoining:items)}
}
