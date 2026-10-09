import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  toolSchemas as legacyToolSchemas,
  instructions,
  type ToolName as LegacyToolName,
} from "./tool-contracts.js";
import type { Backend } from "./broker.js";
import { reviewToolSchemas, reviewDescriptions } from "./review-contracts.js";
const toolSchemas = { ...legacyToolSchemas, ...reviewToolSchemas };
type ToolName = LegacyToolName | keyof typeof reviewToolSchemas;
const descriptions: Record<ToolName, string> = {
  ...reviewDescriptions,
  demonstrate_line:
    "Start a reversible visual demonstration from the current real practice position. Supply up to 3 labeled lines of at most 12 legal UCI moves, each optionally with explanation, arrows and highlights. All moves are validated atomically. Defaults paused; autoplay is optional. Does not commit moves, overwrite a learner preview, or work in quizzes. Return includes demonstrationId as demonstration.id and validated SAN/FEN frames. These are possible lines, not verified best/forced variations.",
  control_demonstration:
    "Play, pause, seek, or close the current demonstration. Use its current demonstrationId and real positionId. seek requires ply and optionally line (zero-based). Other actions omit line/ply. Learner pause and dismissal take precedence: never restart without invitation. Closing restores the real board; no move can be committed through this tool.",
  get_turn_brief:
    "Read the latest practice turn, verified attacks/material, automatically prepared guidance and the learner’s hypothetical test move. Real state and preview are separate. Use after Black replies; guided mode is ongoing permission for suggestions.",
  preview_move:
    "Analyze a legal White candidate without playing it. Returns verified move facts, remaining attacks, approximate engine comparison and hypothetical continuation frames. Never commits or changes the visible board. Use to substantiate tactical explanations.",
  show_preview:
    "Display a frame of the learner’s existing Try a move analysis on the board. Candidate and recommended continuations are hypothetical; this never commits a move. Requires a ready user-selected preview and current position. Explain the displayed reply, then return to ply 1; the learner chooses Play this move or Return to game.",
  inspect_piece:
    "Choose target=display to inspect the shown preview/demonstration frame; default game inspects the real game. Read display.identity from get_session before describing the shown board. Inspect either side’s piece: attacked/defended squares and legal destinations for the side to move, or explicitly hypothetical movement out of turn. Never moves a piece.",
  get_session:
    "Read the current board, role, revision and supported capabilities. Start here. No hidden quiz answers or future lesson text.",
  get_legal_moves:
    "List legal practice-game moves for the observed revision. Unavailable in quizzes and partial teaching positions.",
  analyze_position:
    "Get bounded Stockfish analysis of a practice position. Scores are from White’s perspective, not win probabilities. Follow the coaching mode; guided play is ongoing permission for hints.",
  play_move:
    "As Opponent only, ask Checkmate to choose and play one legal Black move at its configured strength. Never moves White. Reuse requestId when retrying an uncertain result.",
  show_annotation:
    "Temporarily highlight squares or draw arrows on the current board. During a demonstration also provide its demonstrationId, line and ply to target the exact displayed frame. Does not answer a quiz, play a move, or advance a lesson.",
  clear_annotations:
    "Clear this companion’s annotations for the current position; authored lesson annotations remain.",
  wait_for_change:
    "Wait up to 20 seconds for a board, lesson or connection change. Returns changed=false on timeout. Does not start voice or wake an idle conversation. Stop when the user stops; never busy-poll.",
};
export function createServer(backend: Backend) {
  const server = new McpServer(
    { name: "checkmate-companion", version: "0.3.0" },
    { instructions, maxToolInputElements: 4096 },
  );
  for (const name of Object.keys(toolSchemas) as ToolName[]) {
    server.registerTool(
      name,
      {
        description: descriptions[name],
        inputSchema: toolSchemas[name],
        annotations: {
          readOnlyHint: ![
            "open_review", "select_review_position", "analyze_review", "cancel_review_analysis", "preview_review_line", "clear_review_preview", "start_practice_from_review",
            "demonstrate_line",
            "control_demonstration",
            "play_move",
            "show_annotation",
            "clear_annotations",
            "show_preview",
          ].includes(name),
          destructiveHint: false,
          openWorldHint: false,
        },
      },
      async (args: Record<string, unknown>, extra: { signal: AbortSignal }) => {
        const parsed = toolSchemas[name].safeParse(args);
        const result = parsed.success
          ? await backend.call(name, parsed.data, extra.signal)
          : {
              error: {
                code: "INVALID_ARGUMENT",
                message: "Arguments do not match the schema.",
              },
            };
        const value = result as Record<string, unknown>;
        return {
          content: [{ type: "text" as const, text: JSON.stringify(value) }],
          structuredContent: value,
          isError: !!value.error,
        };
      },
    );
  }
  server.server.onclose = () => {
    void backend.close?.();
  };
  return server;
}
