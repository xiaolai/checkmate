import XCTest
@testable import CheckmateCore
final class LessonSettingsPersistenceTests:XCTestCase {
    func testOldStateDefaultsAndSelectionsAreIndependent() throws {
        let old=try JSONDecoder().decode(AppSettings.self,from:Data("{\"voiceLanguage\":\"ja\"}".utf8))
        XCTAssertEqual(old.lessonLanguage,"en");XCTAssertEqual(old.lessonVoice,"cedar");XCTAssertEqual(old.voiceLanguage,"ja")
        let selection=AppSettings(raw:["lessonLanguage":"zh-Hans","lessonVoice":"marin","voiceLanguage":"es"])
        let restored=try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(selection))
        XCTAssertEqual(restored.lessonLanguage,"zh-Hans");XCTAssertEqual(restored.lessonVoice,"marin");XCTAssertEqual(restored.voiceLanguage,"es")
    }
    func testInvalidLanguageAndVoiceUseSafeDefaults(){
        for language in ["../zh","en--US","",String(repeating:"a",count:65)]{XCTAssertEqual(AppSettings(raw:["lessonLanguage":language]).lessonLanguage,"en")}
        XCTAssertEqual(AppSettings(raw:["lessonVoice":"unknown"]).lessonVoice,"cedar")
    }
}
extension LessonSettingsPersistenceTests {
    func testCustomLanguageCanonicalizationRejectsUnknownLabels(){
        XCTAssertEqual(LessonLanguages.normalizedSelection(" FR "),"fr")
        XCTAssertEqual(LessonLanguages.normalizedSelection("zh-hans"),"zh-Hans")
        XCTAssertEqual(LessonLanguages.normalizedSelection("en-us"),"en-US")
        XCTAssertNil(LessonLanguages.normalizedSelection("nonsense"))
        XCTAssertNil(LessonLanguages.normalizedSelection("zz"))
        XCTAssertNil(LessonLanguages.normalizedSelection("fr-nonsense"))
        XCTAssertNil(LessonLanguages.normalizedSelection("fr-Qwer"))
        XCTAssertNil(LessonLanguages.normalizedSelection("en-US-GB"))
    }
    /// The validator's code sets come from Foundation's current Locale APIs: countries only (not groupings such as EU
    /// or UN), and only scripts an identifier names explicitly (English is not "Latn" by inference).
    func testLanguageRegionAndScriptSetsKeepTheirMeaning(){
        XCTAssertEqual(LessonLanguages.normalizedSelection("pt-br"),"pt-BR");XCTAssertEqual(LessonLanguages.normalizedSelection("sr-latn"),"sr-Latn")
        XCTAssertEqual(LessonLanguages.normalizedSelection("pa-guru"),"pa-Guru");XCTAssertEqual(LessonLanguages.normalizedSelection("es-419"),"es-419")
        for grouping in ["en-eu","en-un","en-ez","en-qo"]{XCTAssertNil(LessonLanguages.normalizedSelection(grouping),grouping)}
    }
}
