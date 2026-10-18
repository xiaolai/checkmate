import Foundation

/// Mini-games plan WI-023 (D7): what a 1.1 Mac wrote for a hosted standard-start game, captured from the 1.1 code at
/// e35e5ef before any 1.2 change. The games are `Legacy11Fixtures.assistedRecord` and `.record` of the domain tests
/// (e4 e5 Nf3, the host White, the guest Ben): the crash-file entry for Ben's part, the review record dated
/// 2026-10-18 (UTC), and the TXT entries of both listeners. Do not regenerate them.
enum Legacy11CoreFixtures {
    static let assistedCrashEntry=#"{"game":{"assistance":{"black":"off","white":"hints"},"assistedPlies":[1],"blackName":"Ben","gameID":"5QVHHR37H3BVYSNN9EN96BYBBC","hostSide":"w","pgn":"[Event \"?\"]\n[Site \"?\"]\n[Date \"????.??.??\"]\n[Round \"?\"]\n[White \"?\"]\n[Black \"?\"]\n[Result \"*\"]\n\n1. e4 e5 2. Nf3 *","revision":3,"timeControl":"untimed","whiteName":"Ana"},"part":"black"}"#
    static let crashEntry=#"{"game":{"blackName":"Ben","gameID":"27BTBDZ9A8Z6WAJ8Z3YB46856C","hostSide":"w","pgn":"[Event \"?\"]\n[Site \"?\"]\n[Date \"????.??.??\"]\n[Round \"?\"]\n[White \"?\"]\n[Black \"?\"]\n[Result \"*\"]\n\n1. e4 e5 2. Nf3 *","revision":3,"timeControl":"untimed","whiteName":"Ana"},"part":"black"}"#
    static let assistedReview="[Event \"Checkmate network game\"]\n[Site \"?\"]\n[Date \"2026.10.18\"]\n[Round \"?\"]\n[White \"Ana\"]\n[Black \"Ben\"]\n[Result \"*\"]\n[TimeControl \"-\"]\n[Assistance \"White: Hints on request; Black: Off\"]\n\n1. e4 {Hint shown} e5 2. Nf3 *"
    static let review="[Event \"Checkmate network game\"]\n[Site \"?\"]\n[Date \"2026.10.18\"]\n[Round \"?\"]\n[White \"Ana\"]\n[Black \"Ben\"]\n[Result \"*\"]\n[TimeControl \"-\"]\n\n1. e4 e5 2. Nf3 *"
    /// Each listener's TXT entries, by role.
    static let assistedTXT:[String:[String:String]]=["seat":["assist":"ho","game":"5QVHHR37H3BVYSNN9EN96BYBBC","role":"seat"],"watch":["assist":"ho","game":"5QVHHR37H3BVYSNN9EN96BYBBC","role":"watch"]]
    static let txt:[String:[String:String]]=["seat":["assist":"oo","game":"27BTBDZ9A8Z6WAJ8Z3YB46856C","role":"seat"],"watch":["assist":"oo","game":"27BTBDZ9A8Z6WAJ8Z3YB46856C","role":"watch"]]
}
