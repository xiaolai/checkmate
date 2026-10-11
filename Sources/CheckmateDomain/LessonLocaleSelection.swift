import CheckmateAssets
import Foundation

extension LessonLanguages {
    /// UN M.49 area codes registered as BCP 47 region subtags (IANA language subtag registry), such as 419 in es-419.
    static let numericRegions:Set<String>=["001","002","003","005","009","011","013","014","015","017","018","019","021","029","030","034","035","039","053","054","057","061","142","143","145","150","151","154","155","202","419"]
    private static let scripts=Set(Locale.availableIdentifiers.compactMap{Locale(identifier:$0).scriptCode})
    /// Normalizes user-entered language IDs and rejects unrecognized language/region tags. A paid job runs only for a
    /// language that is its own normalized form, whatever path (Settings, imported progress) supplied it.
    public static func normalizedSelection(_ input:String)->String? {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard valid(value) else{return nil}
        var parts=value.split(separator:"-").map(String.init)
        let language=parts[0].lowercased()
        guard Locale.isoLanguageCodes.contains(language) else{return nil}
        guard parts.count<=3 else{return nil}
        var hasScript=false,hasRegion=false
        parts[0]=language
        for index in 1..<parts.count {
            let part=parts[index]
            if part.count==4,part.allSatisfy(\.isLetter) {
                let script=part.prefix(1).uppercased()+part.dropFirst().lowercased()
                guard index==1,!hasScript,!hasRegion,scripts.contains(script) else{return nil}
                hasScript=true;parts[index]=script
            } else if part.count==2,part.allSatisfy(\.isLetter) {
                guard !hasRegion,Locale.isoRegionCodes.contains(part.uppercased()) else{return nil}
                hasRegion=true;parts[index]=part.uppercased()
            } else if part.count==3,part.allSatisfy(\.isNumber) {
                guard !hasRegion,numericRegions.contains(part) else{return nil};hasRegion=true;parts[index]=part
            } else {return nil}
        }
        return parts.joined(separator:"-")
    }
}
