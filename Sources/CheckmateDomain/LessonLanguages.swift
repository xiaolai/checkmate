import CheckmateAssets
import Foundation
public enum LessonLanguages {
 public static let supported=["en","ar","bg","ca","cs","da","de","el","es","et","fa","fi","fr","he","hi","hr","hu","id","is","it","ja","ko","lt","lv","ms","nl","no","pl","pt","ro","ru","sk","sl","sr","sv","sw","ta","th","tr","uk","ur","vi","zh-Hans","zh-Hant"]
 public static func valid(_ locale:String)->Bool {locale.count<=48 && locale.range(of:"^[A-Za-z]{2,8}(-[A-Za-z0-9]{2,8})*$",options:.regularExpression) != nil}
 public static func name(_ locale:String)->String {Locale(identifier:"en").localizedString(forIdentifier:locale) ?? locale}
}
