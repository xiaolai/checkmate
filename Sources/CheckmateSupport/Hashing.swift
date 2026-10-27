import CheckmateDomain
import Foundation
import CryptoKit
/// SHA-256 as lower-case hex: the one spelling of a content hash in this app.
public func reviewHash(_ data:Data)->String {hex(SHA256.hash(data:data))}
/// Whether `text` is spelled as `reviewHash` spells one: 64 lower-case hex digits.
public func isReviewDigest(_ text:String)->Bool {text.count==64 && text.allSatisfy{"0123456789abcdef".contains($0)}}
public func reviewFileHash(_ url:URL)throws -> String {
    let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var hash=SHA256()
    while let data=try file.read(upToCount:64*1024),!data.isEmpty{hash.update(data:data)}
    return hex(hash.finalize())
}
/// At most `limit` bytes of `handle`, read one byte past the limit to tell: nil when there is more, so an oversized
/// file is refused without being loaded whole.
public func readBounded(_ handle:FileHandle,limit:Int)throws -> Data? {
    var data=Data();while data.count<=limit,let chunk=try handle.read(upToCount:limit+1-data.count),!chunk.isEmpty{data.append(chunk)}
    return data.count<=limit ? data:nil
}
private func hex(_ digest:SHA256Digest)->String {digest.map{String(format:"%02x",$0)}.joined()}
