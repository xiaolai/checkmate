import Foundation

extension LessonLanguages {
    /// Normalizes user-entered language IDs and rejects unrecognized language/region tags.
    public static func normalizedSelection(_ input:String)->String? {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard valid(value) else{return nil}
        var parts=value.split(separator:"-").map(String.init)
        let language=parts[0].lowercased()
        guard Locale.isoLanguageCodes.contains(language) else{return nil}
        guard parts.count<=3 else{return nil}
        let scripts=Set(Locale.availableIdentifiers.compactMap{Locale(identifier:$0).scriptCode})
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
                guard !hasRegion else{return nil};hasRegion=true;parts[index]=part
            } else {return nil}
        }
        return parts.joined(separator:"-")
    }
}
