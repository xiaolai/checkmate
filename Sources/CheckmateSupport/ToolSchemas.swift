import CheckmateDomain
import CheckmateAssets
import Foundation
import CoreFoundation
public struct ProtocolFailure:Error {public let code:String,message:String;public init(_ code:String,_ message:String?=nil){self.code=code;self.message=message ?? code};public var result:[String:Any]{["error":["code":code,"message":message]]}}
public struct ToolSchemas {
    private let schemas:[String:[String:Any]]
    public init() throws {schemas=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("tool-schemas.json"))) as! [String:[String:Any]]}
    public var names:[String] {Array(schemas.keys).sorted()}
    public func parse(_ name:String,args:[String:Any]) throws -> [String:Any] {guard let schema=schemas[name] else{throw ProtocolFailure("INVALID_ARGUMENT")};return try Self.validateValue(args,schema:schema) as! [String:Any]}
    public static func validateValue(_ value:Any,schema:[String:Any]) throws -> Any {
        func fail() throws -> Never {throw ProtocolFailure("INVALID_ARGUMENT","Arguments do not match the tool schema.")}
        if let values=schema["enum"] as? [String],let text=value as? String,!values.contains(text){try fail()}
        switch schema["type"] as? String {
        case "object":guard var object=value as? [String:Any] else{try fail()};let properties=schema["properties"] as? [String:[String:Any]] ?? [:]
            if schema["additionalProperties"] as? Bool==false,!Set(object.keys).isSubset(of:Set(properties.keys)){try fail()}
            for key in schema["required"] as? [String] ?? [] where object[key]==nil {try fail()}
            for (key,s) in properties {if let v=object[key]{object[key]=try Self.validateValue(v,schema:s)}else if let v=s["default"]{object[key]=v}}
            return object
        case "string":guard let text=value as? String else{try fail()};let count=text.utf16.count;if count<(schema["minLength"] as? Int ?? 0) || count>(schema["maxLength"] as? Int ?? Int.max){try fail()};if let pattern=schema["pattern"] as? String,text.range(of:pattern,options:.regularExpression)==nil{try fail()};return text
        case "integer","number":guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite else{try fail()};let n=number.doubleValue;if schema["type"] as? String=="integer",floor(n) != n{try fail()};if n<(schema["minimum"] as? Double ?? -Double.greatestFiniteMagnitude)||n>(schema["maximum"] as? Double ?? Double.greatestFiniteMagnitude){try fail()};return value
        case "boolean":guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{try fail()};return value
        case "array":guard let array=value as? [Any],array.count>=(schema["minItems"] as? Int ?? 0),array.count<=(schema["maxItems"] as? Int ?? Int.max) else{try fail()};let tuple=(schema["prefixItems"] as? [[String:Any]]) ?? (schema["items"] as? [[String:Any]]);return try array.enumerated().map {i,v in if let tuple=tuple,tuple.indices.contains(i){return try Self.validateValue(v,schema:tuple[i])};if let s=schema["items"] as? [String:Any]{return try Self.validateValue(v,schema:s)};if schema["items"] as? Bool==false{try fail()};return v}
        default:return value
        }
    }
}
