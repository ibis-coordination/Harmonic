/**
 * Step record construction — pure functions.
 * Produces step detail objects matching Ruby AgentNavigator's step structure exactly.
 * Each step type has a specific detail schema (see AgentNavigator.add_step calls).
 */

export interface StepRecord {
  readonly type: string;
  readonly detail: Record<string, unknown>;
  readonly timestamp: string;
  /** McpToolCallLog id from _meta.harmonic.tool_call_log_id on the MCP response. Null for loop-internal step types. */
  readonly mcp_tool_call_log_id?: string | null;
}

/**
 * Build a fetch_page step record (formerly "navigate" before the agent-runner
 * migrated to /mcp; the underlying behavior is the same — read a page).
 */
export function fetchPageStep(detail: {
  readonly path: string;
  readonly resolvedPath: string;
  readonly contentPreview: string;
  readonly availableActions: readonly string[];
  readonly error: string | null;
  readonly mcp_tool_call_log_id: string | null;
}, timestamp: Date): StepRecord {
  return {
    type: "fetch_page",
    detail: {
      path: detail.path,
      resolved_path: detail.resolvedPath,
      content_preview: detail.contentPreview,
      available_actions: detail.availableActions,
      error: detail.error,
    },
    timestamp: timestamp.toISOString(),
    mcp_tool_call_log_id: detail.mcp_tool_call_log_id,
  };
}

/**
 * Build an execute_action step record (formerly "execute" before the
 * agent-runner migrated to /mcp; same behavior — invoke a Harmonic action).
 */
export function executeActionStep(detail: {
  readonly action: string;
  readonly params: Record<string, unknown>;
  readonly success: boolean;
  readonly contentPreview: string | null;
  readonly error: string | null;
  readonly mcp_tool_call_log_id: string | null;
}, timestamp: Date): StepRecord {
  return {
    type: "execute_action",
    detail: {
      action: detail.action,
      params: detail.params,
      success: detail.success,
      content_preview: detail.contentPreview,
      error: detail.error,
    },
    timestamp: timestamp.toISOString(),
    mcp_tool_call_log_id: detail.mcp_tool_call_log_id,
  };
}

/**
 * Compact summary of a single tool call emitted by the LLM, stored on the
 * think step so the timeline can show *what the LLM asked for* even when
 * response_preview is empty (common when the model emits only tool calls).
 */
export interface ToolCallSummary {
  readonly name: string;
  readonly arguments: string;
}

/**
 * Build a think step record.
 * Matches Ruby: add_step("think", { step_number:, prompt_preview:, response_preview:, llm_error: })
 * llm_error, tool_calls, and reasoning are only included when present.
 */
export function thinkStep(detail: {
  readonly stepNumber: number;
  readonly promptPreview: string;
  readonly responsePreview: string;
  readonly llmError: string | null;
  readonly toolCalls?: readonly ToolCallSummary[] | undefined;
  readonly reasoning?: string | undefined;
}, timestamp: Date): StepRecord {
  const stepDetail: Record<string, unknown> = {
    step_number: detail.stepNumber,
    prompt_preview: detail.promptPreview,
    response_preview: detail.responsePreview,
  };
  if (detail.llmError !== null) {
    stepDetail["llm_error"] = detail.llmError;
  }
  if (detail.toolCalls !== undefined && detail.toolCalls.length > 0) {
    stepDetail["tool_calls"] = detail.toolCalls.map((tc) => ({
      name: tc.name,
      arguments: tc.arguments,
    }));
  }
  if (detail.reasoning !== undefined && detail.reasoning !== "") {
    stepDetail["reasoning"] = detail.reasoning;
  }
  return {
    type: "think",
    detail: stepDetail,
    timestamp: timestamp.toISOString(),
  };
}

/**
 * Build an error step record.
 * Matches Ruby: add_step("error", { message: })
 */
export function errorStep(detail: {
  readonly message: string;
}, timestamp: Date): StepRecord {
  return {
    type: "error",
    detail: { message: detail.message },
    timestamp: timestamp.toISOString(),
  };
}

/**
 * Build a security warning step record.
 * Matches Ruby: add_step("security_warning", { type: "identity_prompt_leakage", reasons:, step_number: })
 */
export function securityWarningStep(detail: {
  readonly reasons: readonly string[];
  readonly stepNumber: number;
}, timestamp: Date): StepRecord {
  return {
    type: "security_warning",
    detail: {
      type: "identity_prompt_leakage",
      reasons: detail.reasons,
      step_number: detail.stepNumber,
    },
    timestamp: timestamp.toISOString(),
  };
}

/**
 * Build a done step record.
 * Matches Ruby: add_step("done", { message: })
 */
export function doneStep(detail: {
  readonly message: string;
}, timestamp: Date): StepRecord {
  return {
    type: "done",
    detail: { message: detail.message },
    timestamp: timestamp.toISOString(),
  };
}

/**
 * Build a scratchpad_update step record.
 * Matches Ruby: add_step("scratchpad_update", { content: })
 */
export function scratchpadUpdateStep(detail: {
  readonly content: string;
}, timestamp: Date): StepRecord {
  return {
    type: "scratchpad_update",
    detail: { content: detail.content },
    timestamp: timestamp.toISOString(),
  };
}

/**
 * Build a scratchpad_update_failed step record.
 * Matches Ruby: add_step("scratchpad_update_failed", { error: })
 */
export function scratchpadUpdateFailedStep(detail: {
  readonly error: string;
}, timestamp: Date): StepRecord {
  return {
    type: "scratchpad_update_failed",
    detail: { error: detail.error },
    timestamp: timestamp.toISOString(),
  };
}
