import Foundation
/// A function call's arguments as the realtime service streams them, so a call that can no longer be valid ends its
/// turn at once instead of streaming until the turn timeout. Two runaways are caught:
/// - arguments longer than the call's own schema allows (its `limit`), or than the whole-call cap;
/// - an unending stream of whitespace, which OpenAI's JSON-mode documentation warns a model can produce. Whitespace
///   outside strings is insignificant, so one unbroken run of it longer than `maximumWhitespace` is a runaway. Layout
///   is not: indentation comes in short runs between fields, however many fields a long call has.
///
/// The contract: a call is accepted when its schema accepts its values and its insignificant padding is within these
/// allowances. A schema bounds values, not their spelling: JSON writes the value 12 as `12.000…` with any count of
/// zeros (Foundation parses thousands) and as `1.2e1`, and pads with any whitespace. So padding beyond the allowances
/// is refused even when the value it spells is valid, the same way for a streamed call and a finished one
/// (`VoiceCoach.runTool`).
struct VoiceToolArguments {
    /// The whole-call cap `runTool` has always applied to finished arguments.
    static let maximumBytes=65536
    static let maximumWhitespace=1024
    let limit:Int
    /// `whitespace` is all insignificant whitespace so far; `longestRun` its longest unbroken run.
    private(set) var bytes=0,whitespace=0,longestRun=0
    private var run=0
    private var inString=false,escaped=false
    init(limit:Int=Self.maximumBytes){self.limit=min(limit,Self.maximumBytes)}
    /// The call's arguments still fit: false once either runaway is seen. The schema bound counts what the call says,
    /// not its layout, so pretty-printed arguments are measured like compact ones.
    var withinBounds:Bool {bytes<=Self.maximumBytes && bytes-whitespace<=limit && longestRun<=Self.maximumWhitespace}
    mutating func append(_ delta:String){
        bytes+=delta.utf8.count
        for byte in delta.utf8 {
            if inString {if escaped{escaped=false}else if byte==0x5C{escaped=true}else if byte==0x22{inString=false}}
            else if byte==0x20 || byte==0x0A || byte==0x0D || byte==0x09{whitespace+=1;run+=1;longestRun=max(longestRun,run);continue}
            else if byte==0x22{inString=true}
            run=0
        }
    }
    /// The most bytes any arguments valid under `schema` can take, every string escaped as `\uXXXX` per UTF-16 unit (the
    /// unit `ToolSchemas` counts lengths in; an astral character is two); nil when a string or array in it has no
    /// bound, so only the whole-call cap applies. A numeral is allowed 24 bytes, the longest a serializer writes for any
    /// 64-bit value; the only numbers the offered tools take are small integers, so any longer spelling is padding.
    static func limit(schema:[String:Any])->Int? {
        if let values=schema["enum"] as? [Any] {return values.map{value in (value as? String).map{$0.utf16.count*6+2} ?? (try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]).count) ?? 0}.max()}
        switch schema["type"] as? String {
        case "string":if let length=schema["maxLength"] as? Int{return length*6+2};return schema["pattern"] == nil ? nil:64
        case "integer","number":return 24
        case "boolean":return 5
        case "array":
            guard let count=schema["maxItems"] as? Int else{return nil}
            // Draft 2020-12 writes a tuple as `prefixItems`, draft 07 as an `items` array; either may sit beside one schema.
            let items=(schema["prefixItems"] as? [[String:Any]] ?? [])+(schema["items"] as? [[String:Any]] ?? [])+((schema["items"] as? [String:Any]).map{[$0]} ?? [])
            guard let item=items.isEmpty ? 0:items.map({limit(schema:$0)}).reduce(Optional(0),{a,b in a.flatMap{a in b.map{max(a,$0)}}}) else{return nil}
            return 2+count*(item+1)
        default:
            var total=2
            for (key,value) in schema["properties"] as? [String:[String:Any]] ?? [:] {guard let size=limit(schema:value) else{return nil};total+=key.utf8.count*6+4+size}
            return total
        }
    }
}
