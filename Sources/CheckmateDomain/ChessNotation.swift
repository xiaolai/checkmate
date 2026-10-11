import Foundation
public enum ChessNotation {
    public static let squares=(1...8).flatMap {r in "abcdefgh".map {String($0)+String(r)}}
    public static func validSquare(_ s:String)->Bool {s.count==2 && s.first.map{"abcdefgh".contains($0)}==true && s.last.map{"12345678".contains($0)}==true}
    public static func validUCI(_ s:String)->Bool {(s.count==4 || s.count==5) && validSquare(String(s.prefix(2))) && validSquare(String(s.dropFirst(2).prefix(2))) && (s.count==4 || "qrbn".contains(s.last!))}
}
