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
import { TaskReporter } from "./TaskReporter.js";
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
} from "../core/PromptBuilder.js";
import { parseToolCalls, validateAction } from "../core/ActionParser.js";
import { RESPOND_TO_HUMAN_TOOL, buildChatSystemPrompt } from "../core/AgentContext.js";
import { extractCanary, checkLeakage } from "../core/LeakageDetector.js";
import {
  navigateStep,
  executeStep,
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

const PAGE_CONTENT_MAX_LENGTH = 4000;

/** Outcome of a task execution, for stats tracking in the main loop. */
export type TaskOutcome = { readonly outcome: "completed" | "failed" | "cancelled" };

/**
 * Run a single agent task to completion.
 * Returns the outcome so the caller can track stats.
 */
export const runTask = (task: TaskPayload): Effect.Effect<TaskOutcome, never, LLMClient | HarmonicClient | TaskReporter | Config> =>
  Effect.gen(function* () {
    const llm = yield* LLMClient;
    const harmonic = yield* HarmonicClient;
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

    // Mutable state matching Ruby AgentNavigator
    const steps: StepRecord[] = [];
    let messages: readonly Message[] = [];
    let currentPath: string | null = null;
    let currentContent: string | null = null;
    let currentActions: readonly string[] = [];
    let lastActionResult: string | null = null;
    let totalInputTokens = 0;
    let totalOutputTokens = 0;
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

    // Helper: navigate (matches Ruby navigate_to)
    // Ruby's MarkdownUiService.navigate catches all errors and returns {content:"", error:...}
    // We do the same: catch HarmonicApiError, record a step with the error, continue.
    const navigateTo = (path: string) =>
      Effect.gen(function* () {
        const result = yield* harmonic.navigate(path, token, subdomain).pipe(
          Effect.catchAll((err) =>
            Effect.succeed({
              content: "",
              availableActions: [] as readonly string[],
              resolvedPath: path,
              _error: err.message,
            }),
          ),
        );

        currentPath = result.resolvedPath;
        currentActions = result.availableActions;
        lastActionResult = null; // Cleared on navigate, matching Ruby

        const navError = "_error" in result ? (result as { _error: string })._error : null;
        currentContent = navError
          ? `Error navigating to ${path}: ${navError}`
          : result.content;

        yield* addStep(navigateStep({
          path,
          resolvedPath: result.resolvedPath,
          contentPreview: result.content,
          availableActions: [...result.availableActions],
          error: navError,
        }, new Date()));

        return result;
      });

    // Helper: execute action (matches Ruby execute_action)
    const executeAction = (actionName: string, params: Record<string, unknown>) =>
      Effect.gen(function* () {
        // Validate action exists, matching Ruby
        const validation = validateAction(actionName, currentActions);
        if (!validation.valid) {
          const errorMsg = `Invalid action '${actionName}'. Available actions: ${[...currentActions].join(", ")}`;
          yield* addStep(executeStep({
            action: actionName,
            params,
            success: false,
            contentPreview: null,
            error: errorMsg,
          }, new Date()));
          lastActionResult = `FAILED: ${errorMsg}`;
          return;
        }

        const result = yield* harmonic.executeAction(
          currentPath ?? "/",
          actionName,
          params,
          token,
          subdomain,
        ).pipe(
          Effect.catchAll((err) =>
            Effect.succeed({ content: "", success: false, _error: err.message }),
          ),
        );

        const execError = "_error" in result
          ? (result as { _error: string })._error
          : (result.success ? null : result.content);

        yield* addStep(executeStep({
          action: actionName,
          params,
          success: result.success,
          contentPreview: result.content,
          error: execError,
        }, new Date()));

        if (result.success) {
          lastActionResult = `SUCCESS: ${actionName} completed. ${result.content.slice(0, 200)}`;
          if (result.content !== "") currentContent = result.content;
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
      // Chat mode: fetch history (includes current_state), restore navigation
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
      const savedPath = historyResponse.current_state.current_path;

      // Always fetch /whoami for fresh identity content (scratchpad, prompt may change)
      const whoamiResult = yield* navigateTo("/whoami");
      leakageDetector = extractCanary(whoamiResult.content);

      // Navigate to saved path if different from /whoami
      if (savedPath && savedPath !== "/whoami") {
        yield* navigateTo(savedPath);
      }

      const scratchpadMatch = /## Scratchpad\s*\n([\s\S]*?)(?:\n##|$)/.exec(whoamiResult.content);
      const scratchpad = scratchpadMatch?.[1]?.trim();

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

      const chatSystemPrompt = buildChatSystemPrompt(whoamiResult.content, scratchpad, timeSinceLastMessage);
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

      chatMessages.push(userMessage(task.task));
      messages = chatMessages;
    } else {
      // Task mode: always start at /whoami
      const whoamiResult = yield* navigateTo("/whoami");
      leakageDetector = extractCanary(whoamiResult.content);

      const scratchpadMatch = /## Scratchpad\s*\n([\s\S]*?)(?:\n##|$)/.exec(whoamiResult.content);
      const scratchpad = scratchpadMatch?.[1]?.trim();

      messages = buildInitialMessages(task, whoamiResult.content, scratchpad);
    }

    // Step 5: Main agent loop
    // Ruby checks `break if @steps.count >= max_steps` BEFORE think()
    let finalMessage: string | undefined;
    let taskOutcome: string | undefined;
    let wasCancelled = false;

    // The main loop is wrapped in an Effect so we can catch unhandled errors
    // (matches Ruby rescue StandardError around run_with_token)
    const mainLoop = Effect.gen(function* () {
      while (steps.length < task.maxSteps) {
        // Check for cancellation before each LLM call
        yield* reporter.checkCancellation(task.taskRunId, subdomain);

        // Call LLM (matches Ruby think())
        // Ruby's LLMClient.chat never raises — it catches all errors and returns Result with error field.
        // We do the same: catch LLMError, record think step with llm_error, treat as error action.
        const llmResult = yield* llm.chat(
          messages,
          task.model,
          tools,
          task.stripeCustomerStripeId,
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

        // Record "think" step (matches Ruby think() recording)
        yield* addStep(thinkStep({
          stepNumber: stepNumberForThink,
          promptPreview: messages[messages.length - 1]?.content ?? "",
          responsePreview: response.content ?? "",
          llmError: null,
        }, new Date()));

        // Add assistant response to history
        messages = [...messages, assistantMessage(response.content, response.toolCalls)];

        // Parse tool calls
        const actions = parseToolCalls(response.toolCalls, response.content);

        // If no tool calls (done), handle it
        if (actions.length === 1 && actions[0]?.type === "done") {
          finalMessage = actions[0].content;
          // In chat mode, report the response as a message step so it gets broadcast
          if (isChatTurn && finalMessage !== "") {
            yield* reportChatMessage(finalMessage);
            yield* addStep(doneStep({ message: "Chat turn complete" }, new Date()));
          } else {
            yield* addStep(doneStep({ message: finalMessage }, new Date()));
          }
          taskOutcome = "completed";
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
            case "navigate": {
              yield* navigateTo(action.path);
              toolResults.push(truncateContent(currentContent ?? ""));
              break;
            }
            case "execute_action": {
              yield* executeAction(action.action, action.params ?? {});
              toolResults.push(lastActionResult ?? "");
              break;
            }
            case "search": {
              yield* navigateTo(`/search?q=${encodeURIComponent(action.query)}`);
              toolResults.push(truncateContent(currentContent ?? ""));
              break;
            }
            case "get_help": {
              yield* navigateTo(`/help/${encodeURIComponent(action.topic)}`);
              toolResults.push(truncateContent(currentContent ?? ""));
              break;
            }
            case "error": {
              yield* addStep(errorStep({ message: action.message }, new Date()));
              finalMessage = action.message;
              taskOutcome = "error";
              toolResults.push(`Error: ${action.message}`);
              taskDone = true;
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
              finalMessage = action.content;
              yield* addStep(doneStep({ message: action.content }, new Date()));
              taskOutcome = "completed";
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
      currentState: isChatTurn ? { current_path: currentPath ?? undefined } : undefined,
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
  if (content.length > PAGE_CONTENT_MAX_LENGTH) {
    return content.slice(0, PAGE_CONTENT_MAX_LENGTH);
  }
  return content;
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
      task.stripeCustomerStripeId,
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
