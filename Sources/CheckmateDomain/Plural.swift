import Foundation
/// Counted text is a localized string whose catalog entry carries plural variations, so a translation replaces the
/// whole sentence and never a suffix glued to an English stem (D-13). Lists are joined here by the system.
public enum Plural {
    /// A list read as a sentence ("a, b and c"), joined by the system rather than by English separators.
    public static func list(_ items:[String])->String {ListFormatter.localizedString(byJoining:items)}
}
