import { Context, Effect, Layer, Ref } from "effect";
import { ConfigService } from "../config/Config.js";
import { McpClientError } from "../errors/Errors.js";

export interface NavigateResult {
  content: string;
  path: string;
}

export interface ExecuteActionResult {
  content: string;
}

export class McpClient extends Context.Tag("McpClient")<
  McpClient,
  {
    readonly navigate: (path: string) => Effect.Effect<NavigateResult, McpClientError>;
    readonly executeAction: (
      action: string,
      params?: Record<string, unknown>
    ) => Effect.Effect<ExecuteActionResult, McpClientError>;
    readonly getCurrentPath: Effect.Effect<string | null>;
  }
>() {}

export const McpClientLive = Layer.effect(
  McpClient,
  Effect.gen(function* () {
    const config = yield* ConfigService;
    const currentPathRef = yield* Ref.make<string | null>(null);

    const navigate = (path: string): Effect.Effect<NavigateResult, McpClientError> =>
      Effect.gen(function* () {
        const normalizedPath = path.startsWith("/") ? path : `/${path}`;
        const fullUrl = `${config.harmonicBaseUrl}${normalizedPath}`;

        const response = yield* Effect.tryPromise({
          try: () =>
            fetch(fullUrl, {
              method: "GET",
              headers: {
                Accept: "text/markdown",
                Authorization: `Bearer ${config.harmonicApiToken}`,
              },
            }),
          catch: (error) =>
            new McpClientError({
              message: error instanceof Error ? error.message : String(error),
              path: normalizedPath,
            }),
        });

        if (!response.ok) {
          const errorText = yield* Effect.tryPromise({
            try: () => response.text(),
            catch: () =>
              new McpClientError({
                message: "Failed to read error response",
                statusCode: response.status,
                path: normalizedPath,
              }),
          });

          return yield* Effect.fail(
            new McpClientError({
              message: `HTTP ${response.status}: ${errorText.slice(0, 500)}`,
              statusCode: response.status,
              path: normalizedPath,
            })
          );
        }

        yield* Ref.set(currentPathRef, normalizedPath);

        const content = yield* Effect.tryPromise({
          try: () => response.text(),
          catch: (error) =>
            new McpClientError({
              message: error instanceof Error ? error.message : String(error),
              path: normalizedPath,
            }),
        });

        return { content, path: normalizedPath };
      });

    const executeAction = (
      action: string,
      params?: Record<string, unknown>
    ): Effect.Effect<ExecuteActionResult, McpClientError> =>
      Effect.gen(function* () {
        const currentPath = yield* Ref.get(currentPathRef);

        if (!currentPath) {
          return yield* Effect.fail(
            new McpClientError({
              message: "No current path. Call navigate first.",
            })
          );
        }

        // Strip /actions suffix if present
        let basePath = currentPath;
        const actionsWithSlashIndex = basePath.indexOf("/actions/");
        if (actionsWithSlashIndex !== -1) {
          basePath = basePath.substring(0, actionsWithSlashIndex);
        } else if (basePath.endsWith("/actions")) {
          basePath = basePath.substring(0, basePath.length - "/actions".length);
        }

        const actionUrl = `${config.harmonicBaseUrl}${basePath}/actions/${action}`;

        const response = yield* Effect.tryPromise({
          try: () =>
            fetch(actionUrl, {
              method: "POST",
              headers: {
                Accept: "text/markdown",
                "Content-Type": "application/json",
                Authorization: `Bearer ${config.harmonicApiToken}`,
              },
              body: JSON.stringify(params || {}),
            }),
          catch: (error) =>
            new McpClientError({
              message: error instanceof Error ? error.message : String(error),
              path: basePath,
            }),
        });

        if (!response.ok) {
          const errorText = yield* Effect.tryPromise({
            try: () => response.text(),
            catch: () =>
              new McpClientError({
                message: "Failed to read error response",
                statusCode: response.status,
                path: basePath,
              }),
          });

          return yield* Effect.fail(
            new McpClientError({
              message: `HTTP ${response.status}: ${errorText.slice(0, 500)}`,
              statusCode: response.status,
              path: basePath,
            })
          );
        }

        const content = yield* Effect.tryPromise({
          try: () => response.text(),
          catch: (error) =>
            new McpClientError({
              message: error instanceof Error ? error.message : String(error),
              path: basePath,
            }),
        });

        return { content };
      });

    return {
      navigate,
      executeAction,
      getCurrentPath: Ref.get(currentPathRef),
    };
  })
);
