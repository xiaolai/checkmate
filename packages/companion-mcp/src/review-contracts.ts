import { z } from "zod";
const id = z.string().min(1).max(100), number = z.number().int().min(0).max(100000);
const revision = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const observed = { sessionId: id, revision };
const identity = { ...observed, documentId: id, reviewRevision: revision, nodeId: number };
const page = { offset: number.default(0), limit: z.number().int().min(1).max(100).default(50) };
export const reviewToolSchemas = {
  list_review_games: z.strictObject(page),
  open_review: z.strictObject({ ...observed, source: z.enum(["saved", "current", "paste"]), gameId: id.optional(), text: z.string().max(65536).optional(), record: number.optional(), expectedReviewRevision: revision.optional() }),
  get_review: z.strictObject({ ...identity, ...page, pageIdentity: z.string().min(1).max(64).optional() }),
  select_review_position: z.strictObject({ ...identity, targetNode: number }),
  analyze_review: z.strictObject(identity),
  get_review_analysis: z.strictObject({ ...identity, jobId: id }),
  cancel_review_analysis: z.strictObject({ ...identity, jobId: id }),
  preview_review_line: z.strictObject({ ...identity, moves: z.array(z.string().regex(/^[a-h][1-8][a-h][1-8][qrbn]?$/)).min(1).max(32) }),
  clear_review_preview: z.strictObject(identity),
  start_practice_from_review: z.strictObject(identity),
};
export const reviewDescriptions: Record<keyof typeof reviewToolSchemas, string> = {
  list_review_games: "Page locally saved immutable review records. No arbitrary file access.",
  open_review: "Open a saved record, current-game snapshot, or bounded pasted PGN/FEN for read-only review. Does not play moves or start voice. When a review is already open, include its expectedReviewRevision to authorize replacement.",
  get_review: "Read the displayed review identity and page the complete validated move tree, facts and metadata. For offset>0 include pageIdentity=documentHash. Earlier history is unavailable for FEN imports.",
  select_review_position: "Select a validated original node. Requires the exact current document, node and review revision; never edits the imported tree.",
  analyze_review: "Start bounded full-strength history-aware offline analysis, returning a job ID. Quality estimates may remain provisional.",
  get_review_analysis: "Read a matching selected-node job's pending/ready/cancelled/failed status and versioned evidence.",
  cancel_review_analysis: "Cancel one review job; navigation and the imported game remain available.",
  preview_review_line: "Validate a reversible imagined UCI line atomically, then display its initial frame. Both sides can move in the local branch.",
  clear_review_preview: "Return to the exact original review cursor, preserving the original document.",
  start_practice_from_review: "Request the app's concrete confirmation, side and profile selection before creating a separate practice fork. Cannot silently replace an active game.",
};
