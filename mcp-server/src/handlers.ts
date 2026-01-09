// Tool result type
export type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
};

// Configuration for handlers
export type Config = {
  baseUrl: string;
  apiToken: string | undefined;
};

// State management
export type State = {
  currentPath: string | null;
};

export function createState(): State {
  return { currentPath: null };
}

// Navigate handler
export async function handleNavigate(
  path: string,
  config: Config,
  state: State,
  fetchFn: typeof fetch = fetch
): Promise<ToolResult> {
  if (!config.apiToken) {
    return {
      content: [{ type: "text", text: "Error: HARMONIC_API_TOKEN environment variable is not set" }],
      isError: true,
    };
  }

  try {
    const normalizedPath = path.startsWith("/") ? path : `/${path}`;
    const fullUrl = `${config.baseUrl}${normalizedPath}`;

    const response = await fetchFn(fullUrl, {
      method: "GET",
      headers: {
        Accept: "text/markdown",
        Authorization: `Bearer ${config.apiToken}`,
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      return {
        content: [{ type: "text", text: `Error: HTTP ${response.status}: ${errorText.slice(0, 500)}` }],
        isError: true,
      };
    }

    state.currentPath = normalizedPath;
    const markdown = await response.text();

    return {
      content: [{ type: "text", text: markdown }],
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: "text", text: `Error: ${message}` }],
      isError: true,
    };
  }
}

// Execute action handler
export async function handleExecuteAction(
  action: string,
  params: Record<string, unknown> | undefined,
  config: Config,
  state: State,
  fetchFn: typeof fetch = fetch
): Promise<ToolResult> {
  if (!state.currentPath) {
    return {
      content: [{ type: "text", text: "Error: No current path. Call 'navigate' first." }],
      isError: true,
    };
  }

  if (!config.apiToken) {
    return {
      content: [{ type: "text", text: "Error: HARMONIC_API_TOKEN environment variable is not set" }],
      isError: true,
    };
  }

  try {
    const actionUrl = `${config.baseUrl}${state.currentPath}/actions/${action}`;

    const response = await fetchFn(actionUrl, {
      method: "POST",
      headers: {
        Accept: "text/markdown",
        "Content-Type": "application/json",
        Authorization: `Bearer ${config.apiToken}`,
      },
      body: JSON.stringify(params || {}),
    });

    if (!response.ok) {
      const errorText = await response.text();
      return {
        content: [{ type: "text", text: `Error: HTTP ${response.status}: ${errorText.slice(0, 500)}` }],
        isError: true,
      };
    }

    const markdown = await response.text();

    return {
      content: [{ type: "text", text: markdown }],
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: "text", text: `Error: ${message}` }],
      isError: true,
    };
  }
}
