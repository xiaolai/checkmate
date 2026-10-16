import Foundation
/// Random bytes for every identifier, code and secret a network game makes. Injected so tests are deterministic;
/// production uses `system`, which draws from `SystemRandomNumberGenerator`.
public struct NetworkRandom {
    private let source:(Int)->[UInt8]
    public init(_ source:@escaping (Int)->[UInt8]){self.source=source}
    public static var system:NetworkRandom {NetworkRandom{count in var generator=SystemRandomNumberGenerator();return (0..<count).map{_ in UInt8.random(in:.min ... .max,using:&generator)}}}
    /// Exactly `count` bytes. A source that returns another count would silently shorten a secret, so it traps.
    public func bytes(_ count:Int)->[UInt8] {let bytes=source(count);precondition(bytes.count==count,"The random source returned the wrong number of bytes.");return bytes}
}
/// Crockford base-32 (D3): no I, L, O or U, so a code read aloud or typed cannot be mistaken for another.
public enum NetworkBase32 {
    public static let alphabet=Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    /// Most significant bit first; the last symbol is padded with zero bits (the spike's encoding).
    public static func encode(_ bytes:[UInt8])->String {
        var text="",buffer=0,bits=0
        for byte in bytes {buffer=(buffer<<8|Int(byte))&0x1FFF;bits+=8;while bits>=5 {bits-=5;text.append(alphabet[(buffer>>bits)&31])}}
        if bits>0 {text.append(alphabet[(buffer<<(5-bits))&31])}
        return text
    }
    /// A typed code in canonical form: upper case, spaces and hyphens removed, O read as 0 and I or L as 1, as
    /// Crockford specifies. Anything else outside the alphabet, including any non-ASCII character, is refused (nil).
    public static func normalized(_ typed:String)->String? {
        var text=""
        for scalar in typed.unicodeScalars {
            guard scalar.isASCII else{return nil}
            switch Character(scalar).uppercased().first! {
            case " ","-","\t":continue
            case "O":text.append("0")
            case "I","L":text.append("1")
            case let symbol:guard alphabet.contains(symbol) else{return nil};text.append(symbol)
            }
        }
        return text
    }
    /// Exactly `count` alphabet symbols whose padding bits beyond `bits` are zero: one text per value, never two.
    static func canonical(_ text:String,count:Int,bits:Int)->Bool {
        guard text.count==count,let last=text.last,let value=alphabet.firstIndex(of:last),text.allSatisfy(alphabet.contains) else{return false}
        return value&((1<<(count*5-bits))-1)==0
    }
}
/// A hosted game's identity: 128 random bits as 26 symbols (D3). It is the TXT record's `game=`, the PSK salt and
/// identity, and every command's `gameID`. It is public: it names a game, it opens nothing.
public struct NetworkGameID:Hashable,Codable,CustomStringConvertible {
    public static let length=26
    public let text:String
    public init?(_ text:String){guard NetworkBase32.canonical(text,count:Self.length,bits:128) else{return nil};self.text=text}
    public static func random(using random:NetworkRandom)->NetworkGameID {NetworkGameID(NetworkBase32.encode(random.bytes(16)))!}
    /// "Ana's game · K7QD": the last four symbols tell apart two hosts with the same name.
    public var displaySuffix:String {String(text.suffix(4))}
    public var description:String {text}
    public init(from decoder:Decoder)throws {let text=try decoder.singleValueContainer().decode(String.self);guard let id=NetworkGameID(text) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid game ID."))};self=id}
    public func encode(to encoder:Encoder)throws {var container=encoder.singleValueContainer();try container.encode(text)}
}
/// A 128-bit identifier: command, offer, snapshot, ping nonce, host run epoch. Not secret.
public struct NetworkID:Hashable,Codable,CustomStringConvertible {
    public static let length=26
    public let text:String
    public init?(_ text:String){guard NetworkBase32.canonical(text,count:Self.length,bits:128) else{return nil};self.text=text}
    public static func random(using random:NetworkRandom)->NetworkID {NetworkID(NetworkBase32.encode(random.bytes(16)))!}
    public var description:String {text}
    public init(from decoder:Decoder)throws {let text=try decoder.singleValueContainer().decode(String.self);guard let id=NetworkID(text) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid identifier."))};self=id}
    public func encode(to encoder:Encoder)throws {var container=encoder.singleValueContainer();try container.encode(text)}
}
/// 256 random bits: a seat claim (`claimID`) or a seat credential (D4). Its text is internal to this module, and its
/// description, debug description and reflection mirror are redacted, so neither interpolation nor `dump` can put
/// one in a log, a crash file or a view.
public struct NetworkSecret:Hashable,Codable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    public static let length=52
    let text:String
    init?(_ text:String){guard NetworkBase32.canonical(text,count:Self.length,bits:256) else{return nil};self.text=text}
    public static func random(using random:NetworkRandom)->NetworkSecret {NetworkSecret(NetworkBase32.encode(random.bytes(32)))!}
    /// Compares every byte whatever the first difference, so the time taken says nothing about a guess.
    public func matches(_ other:NetworkSecret)->Bool {zip(text.utf8,other.text.utf8).reduce(0){$0|($1.0^$1.1)}==0 && text.utf8.count==other.text.utf8.count}
    public var description:String {"NetworkSecret(redacted)"}
    public var debugDescription:String {description}
    public var customMirror:Mirror {Mirror(self,unlabeledChildren:[Any]())}
    public init(from decoder:Decoder)throws {let text=try decoder.singleValueContainer().decode(String.self);guard let secret=NetworkSecret(text) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid secret."))};self=secret}
    public func encode(to encoder:Encoder)throws {var container=encoder.singleValueContainer();try container.encode(text)}
}
/// A play or watch code: 8 symbols, 40 bits (D3). It keys a listener's PSK, so like a secret it is never described;
/// the interface reads `text` or `grouped`.
public struct NetworkCode:Hashable,CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    public static let length=8
    public let text:String
    /// What the joiner typed, normalised (`NetworkBase32.normalized`); nil unless it is exactly eight symbols.
    public init?(typed:String){guard let text=NetworkBase32.normalized(typed),text.count==Self.length else{return nil};self.text=text}
    public static func random(using random:NetworkRandom)->NetworkCode {NetworkCode(typed:NetworkBase32.encode(random.bytes(5)))!}
    /// "K7QD-2M9X": two groups of four are easier to read out and to type.
    public var grouped:String {String(text.prefix(4))+"-"+String(text.suffix(4))}
    public var description:String {"NetworkCode(redacted)"}
    public var debugDescription:String {description}
    public var customMirror:Mirror {Mirror(self,unlabeledChildren:[Any]())}
}
