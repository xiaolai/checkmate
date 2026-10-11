import CheckmateDomain
import Foundation
import CryptoKit
public func reviewHash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
public func reviewFileHash(_ url:URL)throws -> String {
    let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var hash=SHA256()
    while let data=try file.read(upToCount:64*1024),!data.isEmpty{hash.update(data:data)}
    return hash.finalize().map{String(format:"%02x",$0)}.joined()
}
