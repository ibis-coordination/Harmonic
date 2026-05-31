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

// Fetch a page: pure GET, returns the markdown body. No state, no cursor.
export async function handleFetchPage(
  path: string,
  config: Config,
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
        content: [{ type: "text", text: `Error: HTTP ${response.status}: ${errorText.slice(0, 2000)}` }],
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

// Search handler — delegates to fetch_page with a search URL
export async function handleSearch(
  query: string,
  config: Config,
  fetchFn: typeof fetch = fetch
): Promise<ToolResult> {
  return handleFetchPage(`/search?q=${encodeURIComponent(query)}`, config, fetchFn);
}

// Get help handler — delegates to fetch_page with a help URL
export async function handleGetHelp(
  topic: string,
  config: Config,
  fetchFn: typeof fetch = fetch
): Promise<ToolResult> {
  return handleFetchPage(`/help/${encodeURIComponent(topic)}`, config, fetchFn);
}

// Execute an action on a path. The action URL is built from the passed
// `path` argument, not from any remembered cursor — every call is
// self-contained. We tolerate the agent passing an action URL or a
// query-string-laden path by normalizing back to the bare resource path.
export async function handleExecuteAction(
  path: string,
  action: string,
  params: Record<string, unknown> | undefined,
  config: Config,
  fetchFn: typeof fetch = fetch
): Promise<ToolResult> {
  if (!config.apiToken) {
    return {
      content: [{ type: "text", text: "Error: HARMONIC_API_TOKEN environment variable is not set" }],
      isError: true,
    };
  }

  try {
    // Normalize the path:
    // 1. Ensure leading slash.
    // 2. Strip ?query — action URLs are on the bare resource path.
    // 3. Strip trailing /actions/<name> or /actions — so an agent passing
    //    a verbatim action URL doesn't produce /foo/actions/x/actions/x.
    let basePath = path.startsWith("/") ? path : `/${path}`;
    const queryIndex = basePath.indexOf("?");
    if (queryIndex !== -1) {
      basePath = basePath.substring(0, queryIndex);
    }
    const actionsWithSlashIndex = basePath.indexOf("/actions/");
    if (actionsWithSlashIndex !== -1) {
      basePath = basePath.substring(0, actionsWithSlashIndex);
    } else if (basePath.endsWith("/actions")) {
      basePath = basePath.substring(0, basePath.length - "/actions".length);
    }
    const actionUrl = `${config.baseUrl}${basePath}/actions/${action}`;

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
        content: [{ type: "text", text: `Error: HTTP ${response.status}: ${errorText.slice(0, 2000)}` }],
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
