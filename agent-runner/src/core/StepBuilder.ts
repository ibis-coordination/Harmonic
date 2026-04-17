/**
 * Step record construction — pure functions.
 * Produces step detail objects matching Ruby AgentNavigator's step structure exactly.
 * Each step type has a specific detail schema (see AgentNavigator.add_step calls).
 */

export interface StepRecord {
  readonly type: string;
  readonly detail: Record<string, unknown>;
  readonly timestamp: string;
}

/**
 * Build a navigate step record.
 * Matches Ruby: add_step("navigate", { path:, resolved_path:, content_preview:, available_actions:, error: })
 */
export function navigateStep(detail: {
  readonly path: string;
  readonly resolvedPath: string;
  readonly contentPreview: string;
  readonly availableActions: readonly string[];
  readonly error: string | null;
}, timestamp: Date): StepRecord {
  return {
    type: "navigate",
    detail: {
      path: detail.path,
      resolved_path: detail.resolvedPath,
      content_preview: detail.contentPreview,
      available_actions: detail.availableActions,
      error: detail.error,
    },
    timestamp: timestamp.toISOString(),
  };
}

/**
 * Build an execute step record.
 * Matches Ruby: add_step("execute", { action:, params:, success:, content_preview:, error: })
 */
export function executeStep(detail: {
  readonly action: string;
  readonly params: Record<string, unknown>;
  readonly success: boolean;
  readonly contentPreview: string | null;
  readonly error: string | null;
}, timestamp: Date): StepRecord {
  return {
    type: "execute",
    detail: {
      action: detail.action,
      params: detail.params,
      success: detail.success,
      content_preview: detail.contentPreview,
      error: detail.error,
    },
    timestamp: timestamp.toISOString(),
  };
}

/**
 * Build a think step record.
 * Matches Ruby: add_step("think", { step_number:, prompt_preview:, response_preview:, llm_error: })
 * llm_error is only included if present (non-null).
 */
export function thinkStep(detail: {
  readonly stepNumber: number;
  readonly promptPreview: string;
  readonly responsePreview: string;
  readonly llmError: string | null;
}, timestamp: Date): StepRecord {
  const stepDetail: Record<string, unknown> = {
    step_number: detail.stepNumber,
    prompt_preview: detail.promptPreview,
    response_preview: detail.responsePreview,
  };
  if (detail.llmError !== null) {
    stepDetail["llm_error"] = detail.llmError;
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
