import CheckmateDomain
/// Mixed practice (plan: Mixed Practice): unlabelled cases drawn across skill rows. The next case prefers one the
/// learner has not seen and whose primary skill differs from the previous mixed case, so topics stay interleaved
/// instead of arriving in blocks. Grading is the case's own evaluator; nothing here judges an answer.
enum TrainingMixedController {
    /// Orders a rotated pool: fresh cases first, those of another topic before those of the same one.
    static func order(_ pool:[TrainingScenario],seen:Set<String>,previous:TrainingSkill?)->[TrainingScenario] {
        let rank={(s:TrainingScenario)->Int in (seen.contains(s.cluster) ? 2:0)+(previous != nil && s.primarySkill==previous ? 1:0)}
        return pool.enumerated().sorted{(rank($0.element),$0.offset)<(rank($1.element),$1.offset)}.map(\.element)
    }
}
extension TrainingController {
    /// The primary skill of the learner's last mixed case (the unfinished one shown, if any), so the next one can differ.
    var previousMixedSkill:TrainingSkill? {
        if let active=training.active,active.entry=="mixed-practice"{return active.scenario.primarySkill}
        guard let last=training.attempts.last(where:{$0.entry=="mixed-practice"}) else{return nil}
        return provider?.scenario(last.scenarioID)?.primarySkill
    }
}
