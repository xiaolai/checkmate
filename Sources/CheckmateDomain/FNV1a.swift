/// 64-bit FNV-1a of `bytes`: a stable fingerprint, not a secret. Plain Swift keeps the domain free of platform frameworks.
public func fnv1a64<Bytes:Sequence>(_ bytes:Bytes)->UInt64 where Bytes.Element==UInt8 {
    var hash:UInt64=0xcbf29ce484222325
    for byte in bytes {hash=(hash ^ UInt64(byte)) &* 0x100000001b3}
    return hash
}
