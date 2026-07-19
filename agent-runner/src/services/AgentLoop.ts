/**
 * Agent execution loop — Effect service.
 * Orchestrates: decrypt token → preflight → claim → navigate /whoami → LLM loop → scratchpad → complete
 *
 * Must match Ruby AgentNavigator behavior exactly:
 * - Step types: navigate, think, execute, done, error, security_warning, scratchpad_update, scratchpad_update_failed
 * - Step counting: every add_step increments, max_steps checked before think()
 * - Max steps: returns failure with "max_steps_exceeded" error
 * - Scratchpad update runs on done, error, max_steps, and exception
 * - Think steps recorded after every LLM call
 */

import { Effect, pipe } from "effect";
import { LLMClient } from "./LLMClient.js";
import { HarmonicClient } from "./HarmonicClient.js";
import { McpClient } from "./McpClient.js";
import { TaskReporter } from "./TaskReporter.js";
import { createRetryBudget } from "./Retry.js";
import { Config } from "../config/Config.js";
import { log } from "./Logger.js";
import { decryptToken } from "./TokenCrypto.js";
import type { TaskPayload, Message } from "../core/PromptBuilder.js";
import {
  buildInitialMessages,
  buildToolResultMessages,
  assistantMessage,
  systemMessage,
  userMessage,
  getToolDefinitions,
  truncatePageContent,
  elideStalePageContent,
} from "../core/PromptBuilder.js";
import { parseToolCalls } from "../core/ActionParser.js";
import { RESPOND_TO_HUMAN_TOOL, buildChatSystemPrompt } from "../core/AgentContext.js";
import { extractCanary, checkLeakage } from "../core/LeakageDetector.js";
import {
  fetchPageStep,
  executeActionStep,
  thinkStep,
  doneStep,
  errorStep,
  securityWarningStep,
  scratchpadUpdateStep,
  scratchpadUpdateFailedStep,
} from "../core/StepBuilder.js";
import {
  parseScratchpadResponse,
  buildScratchpadPrompt,
} from "../core/ScratchpadParser.js";
import type { StepRecord } from "../core/StepBuilder.js";
import {
  type HarmonicApiError,
  type LLMError,
  type PreflightFailedError,
  type TaskCancelledError,
  TokenDecryptError,
} from "../errors/Errors.js";

type AgentLoopError =
  | LLMError
  | HarmonicApiError
  | PreflightFailedError
  | TaskCancelledError
  | TokenDecryptError;

// Cap on page content handed to the LLM per fetch. Generous by default —
// typical note threads should fit whole; the truncation marker covers the
// rest. Override with the PAGE_CONTENT_MAX_LENGTH env var.
const PAGE_CONTENT_MAX_LENGTH =
  parseInt(process.env["PAGE_CONTENT_MAX_LENGTH"] ?? "", 10) || 24_000;

/** Outcome of a task execution, for stats tracking in the main loop. */
export type TaskOutcome = { readonly outcome: "completed" | "failed" | "cancelled" };

/**
 * Run a single agent task to completion.
 * Returns the outcome so the caller can track stats.
 */
export const runTask = (task: TaskPayload): Effect.Effect<TaskOutcome, never, LLMClient | HarmonicClient | McpClient | TaskReporter | Config> =>
  Effect.gen(function* () {
    const llm = yield* LLMClient;
    const harmonic = yield* HarmonicClient;
    const mcp = yield* McpClient;
    const reporter = yield* TaskReporter;
    const config = yield* Config;
    const subdomain = task.tenantSubdomain;

    // Step 1: Decrypt Bearer token from stream payload.
    //
    // decryptToken throws synchronously on bad base64 / auth-tag / wrong key.
    // Inside Effect.gen, synchronous throws surface as defects (Cause.Die), which
    // bypass Effect.catchAll<AgentLoopError> at the bottom of this pipe — that
    // would leave the task in `queued` forever while the stream entry is ACK'd.
    // Wrap in Effect.try so the failure flows through the typed error channel
    // and reaches reporter.fail below.
    const token = yield* Effect.try({
      try: () => decryptToken(task.encryptedToken, config.agentRunnerSecret),
      catch: (err) => new TokenDecryptError({
        taskRunId: task.taskRunId,
        message: err instanceof Error ? err.message : String(err),
      }),
    });

    // Step 2: Preflight checks (billing, agent status)
    yield* reporter.preflight(task.taskRunId, subdomain);

    // Step 3: Claim the task (mark as running)
    yield* reporter.claim(task.taskRunId, subdomain);

    // Mutable state for the loop. `currentContent` and `lastActionResult` are
    // per-turn scratch — the value of the most recent fetch / action — used
    // only to build the next LLM tool-result message. They are not authority:
    // the agent's tool calls now carry their own `path`, so we no longer need
    // to remember "where the cursor is" across calls or chat turns.
    const steps: StepRecord[] = [];
    let messages: readonly Message[] = [];
    let currentContent: string | null = null;
    let lastActionResult: string | null = null;
    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    // Per-task budget for cumulative Retry-After backoff. Shared across all
    // navigate/executeAction calls in this run; a sustained-throttle scenario
    // can't blow past the budget into the task's wall-clock limit.
    const retryBudget = createRetryBudget();
    const isChatTurn = task.mode === "chat_turn";
    const tools = isChatTurn
      ? [...getToolDefinitions(), RESPOND_TO_HUMAN_TOOL]
      : getToolDefinitions();

    // Helper to add a step and report it to Rails (matches Ruby add_step + persist_step)
    const addStep = (step: StepRecord) =>
      Effect.gen(function* () {
        steps.push(step);
        yield* reporter.step(task.taskRunId, subdomain, [step]).pipe(
          Effect.catchAll((err) => {
            log.error({ event: "step_persist_failed", taskRunId: task.taskRunId, message: String(err) });
            return Effect.void;
          }),
        );
      });

    // Helper: fetch a page. McpClient.fetchPage catches transport and
    // tool-level errors and surfaces them as HarmonicApiError; we catch that
    // and record the error on a step so the loop can continue.
    const fetchPage = (path: string, context?: Record<string, unknown>) =>
      Effect.gen(function* () {
        const result = yield* mcp.fetchPage(path, context, token, subdomain, retryBudget).pipe(
          Effect.catchAll((err) =>
            Effect.succeed({
              content: "",
              availableActions: [] as readonly string[],
              resolvedPath: path,
              mcpToolCallLogId: null,
              _error: err.message,
            }),
          ),
        );

        lastActionResult = null;

        const navError = "_error" in result ? (result as { _error: string })._error : null;
        currentContent = navError
          ? `Error fetching ${path}: ${navError}`
          : result.content;

        yield* addStep(fetchPageStep({
          path,
          resolvedPath: result.resolvedPath,
          contentPreview: result.content,
          availableActions: [...result.availableActions],
          error: navError,
          mcp_tool_call_log_id: result.mcpToolCallLogId,
        }, new Date()));

        return result;
      });

    // Helper: execute an action against an explicit path. No client-side
    // validation — Rails is the sole authority on what actions exist at a
    // path and returns a 404 with the available-actions list when the agent
    // guesses wrong. That body is surfaced verbatim in the tool result.
    const executeAction = (context: Record<string, unknown>, path: string, actionName: string, params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const result = yield* mcp.executeAction(
          context,
          path,
          actionName,
          params,
          token,
          subdomain,
          retryBudget,
        ).pipe(
          Effect.catchAll((err) =>
            Effect.succeed({ content: "", success: false, mcpToolCallLogId: null, _error: err.message }),
          ),
        );

        const execError = "_error" in result
          ? (result as { _error: string })._error
          : (result.success ? null : result.content);

        yield* addStep(executeActionStep({
          action: actionName,
          params,
          success: result.success,
          contentPreview: result.content,
          error: execError,
          mcp_tool_call_log_id: result.mcpToolCallLogId,
        }, new Date()));

        if (result.success) {
          lastActionResult = `SUCCESS: ${actionName} completed. ${result.content.slice(0, 200)}`;
        } else {
          const failReason = "_error" in result
            ? (result as { _error: string })._error
            : result.content;
          lastActionResult = `FAILED: ${actionName} failed. ${failReason}`;
        }
      });

    // Helper: report a chat message step to Rails (broadcasts via ActionCable)
    const reportChatMessage = (message: string) =>
      reporter.step(task.taskRunId, subdomain, [{
        type: "message",
        detail: { content: message },
        timestamp: new Date().toISOString(),
        sender_id: task.agentId,
      } as unknown as StepRecord]).pipe(
        Effect.catchAll((err) => {
          log.error({ event: "chat_message_persist_failed", taskRunId: task.taskRunId, message: String(err) });
          return Effect.void;
        }),
      );

    // Step 4: Build context and initial messages
    let leakageDetector: ReturnType<typeof extractCanary>;

    if (isChatTurn && task.chatSessionId !== undefined) {
      // Chat mode: fetch history. Stateless tools mean we don't need to
      // replay a saved current_path — each fetch_page / execute_action call
      // carries its own path, so the new turn can act on any resource the
      // agent's previous turn referenced (or fetch_page first if it needs
      // to re-orient).
      const emptyResponse: import("./HarmonicClient.js").ChatHistoryResponse = {
        messages: [],
        current_state: {},
      };
      const historyResponse = yield* harmonic.fetchChatHistory(task.chatSessionId, subdomain).pipe(
        Effect.catchAll((err) => {
          log.error({ event: "chat_history_fetch_failed", taskRunId: task.taskRunId, message: String(err) });
          return Effect.succeed(emptyResponse);
        }),
      );
      const history = historyResponse.messages;

      // Always fetch /whoami for fresh identity content (scratchpad, prompt may change)
      const whoamiResult = yield* fetchPage("/whoami");
      leakageDetector = extractCanary(whoamiResult.content);

      // Compute time since last message
      let timeSinceLastMessage: string | undefined;
      if (history.length > 0) {
        const lastTimestamp = history[history.length - 1]?.timestamp;
        if (lastTimestamp) {
          const elapsed = Date.now() - new Date(lastTimestamp).getTime();
          if (elapsed > 24 * 60 * 60 * 1000) timeSinceLastMessage = `${Math.round(elapsed / (24 * 60 * 60 * 1000))} days`;
          else if (elapsed > 60 * 60 * 1000) timeSinceLastMessage = `${Math.round(elapsed / (60 * 60 * 1000))} hours`;
          else if (elapsed > 5 * 60 * 1000) timeSinceLastMessage = `${Math.round(elapsed / (60 * 1000))} minutes`;
        }
      }

      const chatSystemPrompt = buildChatSystemPrompt(whoamiResult.content, timeSinceLastMessage);
      const chatMessages: Message[] = [systemMessage(chatSystemPrompt)];

      for (const msg of history) {
        if (msg.role === "user") {
          chatMessages.push(userMessage(msg.content));
        } else if (msg.role === "assistant") {
          chatMessages.push(assistantMessage(msg.content, undefined));
        } else if (msg.role === "system") {
          chatMessages.push(userMessage(msg.content));
        }
      }

      // Rails commits the user's ChatMessage before dispatching the task, so
      // the just-fetched history normally already ends with task.task. Only
      // append it when missing — covers the history-fetch-failed fallback
      // (empty history) and the race where history loads slightly stale.
      const lastHistoryMsg = history[history.length - 1];
      const taskAlreadyTrailing =
        lastHistoryMsg?.role === "user" && lastHistoryMsg.content === task.task;
      if (!taskAlreadyTrailing) {
        chatMessages.push(userMessage(task.task));
      }
      messages = chatMessages;
    } else {
      // Task mode: always start at /whoami
      const whoamiResult = yield* fetchPage("/whoami");
      leakageDetector = extractCanary(whoamiResult.content);

      messages = buildInitialMessages(task, whoamiResult.content);
    }

    // Step 5: Main agent loop
    // Ruby checks `break if @steps.count >= max_steps` BEFORE think()
    let finalMessage: string | undefined;
    let taskOutcome: string | undefined;
    let wasCancelled = false;
    // Set when ActionParser rejects a tool call (missing required field,
    // unknown tool, bad JSON). Recoverable in-turn, but if the loop then
    // exits via implicit `done` (agent stopped emitting tool calls), we
    // demote the outcome so a bail-after-error doesn't get recorded as a
    // clean success. `respond_to_human` still counts as success — the
    // agent explicitly recovered and addressed the human.
    let parserErrorOccurred = false;

    // The main loop is wrapped in an Effect so we can catch unhandled errors
    // (matches Ruby rescue StandardError around run_with_token)
    const mainLoop = Effect.gen(function* () {
      while (steps.length < task.maxSteps) {
        // Check for cancellation before each LLM call
        yield* reporter.checkCancellation(task.taskRunId, subdomain);

        // Call LLM (matches Ruby think())
        // Ruby's LLMClient.chat never raises — it catches all errors and returns Result with error field.
        // We do the same: catch LLMError, record think step with llm_error, treat as error action.
        // Stale page fetches ride along on every call otherwise — see
        // elideStalePageContent. `messages` itself stays complete.
        const llmResult = yield* llm.chat(
          elideStalePageContent(messages),
          task.model,
          tools,
          { taskRunId: task.taskRunId, subdomain: task.tenantSubdomain },
          task.llmGatewayMode,
        ).pipe(
          Effect.map((r) => ({ ok: true as const, response: r })),
          Effect.catchAll((err) =>
            Effect.succeed({ ok: false as const, error: err.message }),
          ),
        );

        const stepNumberForThink = steps.length;

        if (!llmResult.ok) {
          yield* addStep(thinkStep({
            stepNumber: stepNumberForThink,
            promptPreview: messages[messages.length - 1]?.content ?? "",
            responsePreview: "",
            llmError: llmResult.error,
          }, new Date()));

          yield* addStep(errorStep({ message: `LLM error: ${llmResult.error}` }, new Date()));
          finalMessage = `Agent encountered an error: ${llmResult.error}`;
          taskOutcome = "error";
          break;
        }

        const response = llmResult.response;
        totalInputTokens += response.usage.inputTokens;
        totalOutputTokens += response.usage.outputTokens;

        // Check for identity prompt leakage BEFORE adding to history (matches Ruby)
        if (response.content !== undefined) {
          const leakage = checkLeakage(leakageDetector, response.content);
          if (leakage.leaked) {
            yield* addStep(securityWarningStep({
              reasons: [...leakage.reasons],
              stepNumber: stepNumberForThink,
            }, new Date()));
          }
        }

        // Record "think" step (matches Ruby think() recording).
        // Capture toolCalls + reasoning so the timeline can show *what the LLM
        // asked for* even when content is empty — common when the model emits
        // only tool calls (no prose), or when reasoning lives in a separate
        // field (DeepSeek R1, Claude extended thinking, OpenAI o-series).
        yield* addStep(thinkStep({
          stepNumber: stepNumberForThink,
          promptPreview: messages[messages.length - 1]?.content ?? "",
          responsePreview: response.content ?? "",
          llmError: null,
          toolCalls: response.toolCalls.map((tc) => ({
            name: tc.function.name,
            arguments: tc.function.arguments,
          })),
          reasoning: response.reasoning,
        }, new Date()));

        // Add assistant response to history
        messages = [...messages, assistantMessage(response.content, response.toolCalls)];

        // Parse tool calls
        const actions = parseToolCalls(response.toolCalls, response.content);

        // If no tool calls (done), handle it
        if (actions.length === 1 && actions[0]?.type === "done") {
          const doneContent = actions[0].content;
          // In chat mode, report the response as a message step so it gets broadcast
          if (isChatTurn && doneContent !== "") {
            yield* reportChatMessage(doneContent);
            yield* addStep(doneStep({ message: "Chat turn complete" }, new Date()));
          } else {
            yield* addStep(doneStep({ message: doneContent }, new Date()));
          }
          if (parserErrorOccurred) {
            finalMessage = `Agent stopped after a tool-call error: ${doneContent}`;
            taskOutcome = "completed_with_parser_errors";
          } else {
            finalMessage = doneContent;
            taskOutcome = "completed";
          }
          break;
        }

        // Process each tool call
        const toolResults: string[] = [];
        let taskDone = false;

        for (const action of actions) {
          if (taskDone) {
            toolResults.push("Session ended.");
            continue;
          }

          switch (action.type) {
            case "fetch_page": {
              yield* fetchPage(action.path, action.context);
              toolResults.push(truncateContent(currentContent ?? ""));
              break;
            }
            case "execute_action": {
              yield* executeAction(action.context, action.path, action.action, action.params ?? {});
              toolResults.push(lastActionResult ?? "");
              break;
            }
            case "search": {
              yield* fetchPage(`/search?q=${encodeURIComponent(action.query)}`);
              toolResults.push(truncateContent(currentContent ?? ""));
              break;
            }
            case "get_help": {
              yield* fetchPage(`/help/${encodeURIComponent(action.topic)}`);
              toolResults.push(truncateContent(currentContent ?? ""));
              break;
            }
            case "error": {
              // Non-terminal: terminating here would leave the human with no response on a recoverable schema mistake.
              parserErrorOccurred = true;
              yield* addStep(errorStep({ message: action.message }, new Date()));
              toolResults.push(`Error: ${action.message}`);
              break;
            }
            case "respond_to_human": {
              yield* reportChatMessage(action.message);
              finalMessage = action.message;
              yield* addStep(doneStep({ message: "Chat turn complete" }, new Date()));
              taskOutcome = "completed";
              toolResults.push("Message sent to human. Turn complete.");
              taskDone = true;
              break;
            }
            case "done": {
              yield* addStep(doneStep({ message: action.content }, new Date()));
              if (parserErrorOccurred) {
                finalMessage = `Agent stopped after a tool-call error: ${action.content}`;
                taskOutcome = "completed_with_parser_errors";
              } else {
                finalMessage = action.content;
                taskOutcome = "completed";
              }
              toolResults.push("Session ended.");
              taskDone = true;
              break;
            }
          }
        }

        // Add tool results to conversation
        if (response.toolCalls.length > 0) {
          messages = [
            ...messages,
            ...buildToolResultMessages(response.toolCalls, toolResults),
          ];
        }

        if (taskDone) break;
      }
    });

    // Run main loop, catch unhandled errors (matches Ruby rescue StandardError)
    // This catches cancellation, unexpected failures, etc.
    yield* mainLoop.pipe(
      Effect.catchAll((error: unknown) =>
        Effect.gen(function* () {
          const errorMsg = error !== null && typeof error === "object" && "message" in error
            ? String((error as { message: unknown }).message)
            : String(error);
          yield* addStep(errorStep({ message: errorMsg }, new Date()));
          finalMessage = `Agent encountered an error: ${errorMsg}`;
          taskOutcome = "exception";
          if (error !== null && typeof error === "object" && "_tag" in error && (error as { _tag: string })._tag === "TaskCancelledError") {
            wasCancelled = true;
          }
        }),
      ),
    );

    // Handle max steps exceeded (matches Ruby)
    if (taskOutcome === undefined) {
      finalMessage = `Reached maximum steps (${task.maxSteps}) without completing task`;
      taskOutcome = "incomplete - max steps reached";
    }

    const success = taskOutcome === "completed";

    // Step 6: Scratchpad update (runs on all outcomes, matches Ruby)
    // Token usage from scratchpad LLM call is included in final totals (matches Ruby)
    yield* updateScratchpad(task, taskOutcome, finalMessage ?? "", steps.length).pipe(
      Effect.tap((result) => {
        totalInputTokens += result.inputTokens;
        totalOutputTokens += result.outputTokens;
        return addStep(result.step);
      }),
      Effect.catchAll((error) => {
        log.error({ event: "scratchpad_update_failed", taskRunId: task.taskRunId, message: String(error) });
        return addStep(scratchpadUpdateFailedStep({ error: String(error) }, new Date()));
      }),
    );

    // Step 7: Report completion (authoritative write — overwrites incremental step data)
    const errorMsg = success ? undefined : (finalMessage ?? "Unknown error");
    yield* reporter.complete(task.taskRunId, subdomain, {
      success,
      finalMessage,
      error: errorMsg,
      inputTokens: totalInputTokens,
      outputTokens: totalOutputTokens,
      totalTokens: totalInputTokens + totalOutputTokens,
    });

    return { outcome: success ? "completed" : wasCancelled ? "cancelled" : "failed" } as TaskOutcome;
  }).pipe(
    // Last resort: if even the completion/scratchpad fails, try to report failure
    Effect.catchAll((error: AgentLoopError) =>
      pipe(
        TaskReporter,
        Effect.flatMap((reporter) =>
          reporter.fail(task.taskRunId, task.tenantSubdomain, error.message ?? String(error)).pipe(
            Effect.catchAll((reportError) => {
              log.error({ event: "failure_report_failed", taskRunId: task.taskRunId, message: String(reportError) });
              return Effect.void;
            }),
          ),
        ),
        Effect.map(() => ({ outcome: "failed" }) as TaskOutcome),
      ),
    ),
  );

/**
 * Truncate page content to match Ruby's 4000-char limit.
 */
function truncateContent(content: string): string {
  return truncatePageContent(content, PAGE_CONTENT_MAX_LENGTH);
}

interface ScratchpadResult {
  readonly step: StepRecord;
  readonly inputTokens: number;
  readonly outputTokens: number;
}

/**
 * Update the agent's scratchpad after task completion.
 * Matches Ruby prompt_for_scratchpad_update exactly.
 * Returns step record and token usage so caller can accumulate both.
 */
const updateScratchpad = (
  task: TaskPayload,
  outcome: string,
  finalMessage: string,
  stepsCount: number,
): Effect.Effect<ScratchpadResult, LLMError | HarmonicApiError, LLMClient | TaskReporter> =>
  Effect.gen(function* () {
    const llm = yield* LLMClient;
    const reporter = yield* TaskReporter;

    const prompt = buildScratchpadPrompt(task.task, outcome, finalMessage, stepsCount);

    const response = yield* llm.chat(
      [{ role: "user", content: prompt }],
      task.model,
      [], // no tools for scratchpad
      { taskRunId: task.taskRunId, subdomain: task.tenantSubdomain },
      task.llmGatewayMode,
    );

    const usage = { inputTokens: response.usage.inputTokens, outputTokens: response.usage.outputTokens };

    if (response.content !== undefined) {
      const parsed = parseScratchpadResponse(response.content);
      if (parsed.success) {
        yield* reporter.scratchpad(task.taskRunId, task.tenantSubdomain, parsed.scratchpad);
        return { step: scratchpadUpdateStep({ content: parsed.scratchpad }, new Date()), ...usage };
      }
    }

    return { step: scratchpadUpdateStep({ content: "" }, new Date()), ...usage };
  });
