import Foundation
/// Writes `data` atomically, then makes the file readable by the owner only.
public func writePrivately(_ data:Data,to url:URL)throws {try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
/// Creates `url` and any missing parents, readable by the owner only; an existing folder is left as it is.
public func createPrivateDirectory(_ url:URL)throws {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
