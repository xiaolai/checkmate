import { z } from "zod";
export const square = z.string().regex(/^[a-h][1-8]$/);
const id = z.string().min(1).max(100);
const observed = { sessionId: id, revision: z.number().int().nonnegative() };
const mutation = { ...observed, requestId: id };
const demonstrationStep = z
  .object({
    uci: z.string().regex(/^[a-h][1-8][a-h][1-8][qrbn]?$/),
    explanation: z.string().max(500).default(""),
    arrows: z
      .array(z.tuple([square, square]))
      .max(4)
      .default([]),
    highlights: z
      .array(
        z
          .object({ sq: square, kind: z.enum(["go", "no", "focus", "check"]) })
          .strict(),
      )
      .max(8)
      .default([]),
  })
  .strict();
export const demonstrationInput = z
  .object({
    title: z.string().min(1).max(80),
    introduction: z.string().max(500).default(""),
    lines: z
      .array(
        z
          .object({
            label: z.string().min(1).max(60),
            moves: z.array(demonstrationStep).min(1).max(12),
          })
          .strict(),
      )
      .min(1)
      .max(3),
    autoplay: z.boolean().default(false),
  })
  .strict();
export const toolSchemas = {
  demonstrate_line: demonstrationInput
    .extend({ ...mutation, positionId: id })
    .strict(),
  control_demonstration: z
    .object({
      ...mutation,
      positionId: id,
      demonstrationId: id,
      action: z.enum(["play", "pause", "seek", "close"]),
      line: z.number().int().min(0).max(2).optional(),
      ply: z.number().int().min(0).max(12).optional(),
    })
    .strict(),
  get_session: z.object({}).strict(),
  get_turn_brief: z.object({}).strict(),
  inspect_piece: z.object({ ...observed, square, target:z.enum(["game","display"]).default("game") }).strict(),
  preview_move: z
    .object({
      ...observed,
      from: square,
      to: square,
      promotion: z.enum(["q", "r", "b", "n"]).optional(),
    })
    .strict(),
  show_preview: z
    .object({
      ...mutation,
      positionId: id,
      previewId: id,
      line: z.enum(["candidate", "recommended"]),
      ply: z.number().int().min(0).max(7),
    })
    .strict(),
  get_legal_moves: z.object({ ...observed, from: square.optional() }).strict(),
  analyze_position: z
    .object({
      ...observed,
      movetimeMs: z.number().int().min(100).max(1000).default(350),
      multiPv: z.number().int().min(1).max(3).default(1),
    })
    .strict(),
  play_move: z.object(mutation).strict(),
  show_annotation: z
    .object({
      displayIdentity: z.string().min(1).max(300).optional(),
      demonstrationId: id.optional(),
      line: z.number().int().min(0).max(2).optional(),
      ply: z.number().int().min(0).max(12).optional(),
      ...mutation,
      positionId: id,
      arrows: z
        .array(z.tuple([square, square]))
        .max(8)
        .default([]),
      highlights: z
        .array(
          z
            .object({
              sq: square,
              kind: z.enum(["go", "no", "focus", "check"]),
            })
            .strict(),
        )
        .max(16)
        .default([]),
      ttlMs: z.number().int().min(1000).max(30000).default(15000),
    })
    .strict(),
  clear_annotations: z.object({ ...mutation, positionId: id }).strict(),
  wait_for_change: z
    .object({
      sessionId: id,
      cursor: z.number().int().nonnegative(),
      timeoutMs: z.number().int().min(1).max(20000).default(20000),
      event: z.enum(["any", "learner_turn", "coaching"]).default("any"),
    })
    .strict(),
};
export type ToolName = keyof typeof toolSchemas;
export class DomainError extends Error {
  constructor(
    public code: string,
    message = code,
  ) {
    super(message);
  }
}
export function errorResult(error: unknown) {
  return {
    error: {
      code: error instanceof DomainError ? error.code : "INTERNAL_ERROR",
      message:
        error instanceof DomainError
          ? error.message
          : "The request failed. Read the current session and try again.",
    },
  };
}
export const instructions =
  "Checkmate chess companion. First get_session. Respect capabilities and role; never move White or answer a quiz for the learner. Use current sessionId/revision and unique requestId for actions. Coach explains; Opponent requests an app-selected Black move. Respect coachingMode: guided permits continuing suggestions after each Black reply; on_request waits for a question; quiet suppresses unsolicited advice. Use get_turn_brief and position identities to avoid repeats. Use preview_move for verified explanations and candidate comparisons; hypothetical moves never change the real game. Use demonstrate_line for a requested visual explanation or an agreed guided demonstration: up to three legal lines with step explanations and highlights. Default to paused and use control_demonstration to step while speaking. Never overwrite a learner preview, resume after the learner pauses or dismisses without asking, or present a possible line as forced. Never claim a knight attack can be blocked. Keep the host MCP connection alive while playing; temporary clients clear annotations on disconnect. Pause conversation during narration. wait_for_change is bounded: do not spin on timeouts or assume it wakes voice. Stop on disconnect or cancellation. Stored solutions and future lesson text are intentionally unavailable. Never use filesystem or other tools to bypass this boundary. Keep explanations brief and invite the child to think.";
