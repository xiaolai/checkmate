import Foundation
import CoreFoundation
/// Scalars of parsed untrusted JSON (`JSONSerialization`), where a boolean and a number are both an `NSNumber`: each
/// reader asks for the one it means, so `true` never reads as 1 and 1 never reads as `true`.
/// A JSON boolean; nil for anything else, a number included.
public func jsonBool(_ value:Any?)->Bool? {guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return nil};return n.boolValue}
/// A finite JSON number; nil for anything else, a boolean included.
public func jsonNumber(_ value:Any?)->NSNumber? {guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return nil};return n}
/// A whole JSON number within `Int`; nil for anything else, a boolean or a fraction included.
public func jsonInteger(_ value:Any?)->Int? {guard let n=jsonNumber(value),floor(n.doubleValue)==n.doubleValue,abs(n.doubleValue)<Double(Int.max) else{return nil};return n.intValue}
