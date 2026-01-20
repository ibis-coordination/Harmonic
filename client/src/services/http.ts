import { Effect, Context } from "effect"
import {
  NetworkError,
  ApiError,
  NotFoundError,
  UnauthorizedError,
  ValidationError,
  type HttpError,
} from "./errors"

export interface HttpClientConfig {
  readonly baseUrl: string | (() => string)
  readonly credentials?: RequestCredentials
}

export interface HttpClientService {
  readonly get: <T>(path: string) => Effect.Effect<T, HttpError>
  readonly post: <T>(path: string, body?: unknown) => Effect.Effect<T, HttpError>
  readonly put: <T>(path: string, body?: unknown) => Effect.Effect<T, HttpError>
  readonly patch: <T>(path: string, body?: unknown) => Effect.Effect<T, HttpError>
  readonly delete: <T>(path: string) => Effect.Effect<T, HttpError>
}

export const HttpClient = Context.GenericTag<HttpClientService>("HttpClient")

const mapStatusToError = (
  status: number,
  body: unknown,
  path: string,
): HttpError => {
  if (status === 401) {
    return UnauthorizedError({
      message:
        typeof body === "object" && body !== null && "error" in body
          ? String((body as { error: unknown }).error)
          : "Unauthorized",
    })
  }
  if (status === 404) {
    return NotFoundError({
      resource: path.split("/")[1] ?? "resource",
      id: path.split("/")[2] ?? "",
    })
  }
  if (status === 422 || status === 400) {
    const errors =
      typeof body === "object" && body !== null && "errors" in body
        ? (body as { errors: Record<string, string[]> }).errors
        : undefined
    return ValidationError({
      message:
        typeof body === "object" && body !== null && "error" in body
          ? String((body as { error: unknown }).error)
          : "Validation failed",
      ...(errors !== undefined ? { errors } : {}),
    })
  }
  return ApiError({
    status,
    message: `API request failed with status ${String(status)}`,
    body,
  })
}

export const createHttpClient = (config: HttpClientConfig): HttpClientService => {
  const request = <T>(
    method: string,
    path: string,
    body?: unknown,
  ): Effect.Effect<T, HttpError> =>
    Effect.gen(function* () {
      // Compute base URL dynamically to handle studio context changes
      const baseUrl =
        typeof config.baseUrl === "function"
          ? config.baseUrl()
          : config.baseUrl
      const url = `${baseUrl}${path}`
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
        Accept: "application/json",
      }
      const fetchOptions: RequestInit = {
        method,
        headers,
        credentials: config.credentials ?? "include",
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      }

      const response = yield* Effect.tryPromise({
        try: () => fetch(url, fetchOptions),
        catch: (error): HttpError =>
          NetworkError({
            message: error instanceof Error ? error.message : "Network error",
            cause: error,
          }),
      })

      const responseBody = yield* Effect.tryPromise({
        try: () => response.json() as Promise<T>,
        catch: (): HttpError =>
          ApiError({
            status: response.status,
            message: "Failed to parse response body",
            body: null,
          }),
      }).pipe(Effect.catchAll(() => Effect.succeed(null as T)))

      if (!response.ok) {
        return yield* Effect.fail(mapStatusToError(response.status, responseBody, path))
      }

      return responseBody
    })

  return {
    get: <T>(path: string) => request<T>("GET", path),
    post: <T>(path: string, body?: unknown) => request<T>("POST", path, body),
    put: <T>(path: string, body?: unknown) => request<T>("PUT", path, body),
    patch: <T>(path: string, body?: unknown) => request<T>("PATCH", path, body),
    delete: <T>(path: string) => request<T>("DELETE", path),
  }
}

/**
 * Get the API base path from the current URL.
 * If we're in a studio context (URL includes /studios/{handle}),
 * use the studio-scoped API path.
 * This is called on each request to handle navigation between pages.
 */
const getApiBasePath = (): string => {
  // Check if window is defined (for SSR/test compatibility)
  if (typeof window === "undefined") {
    return "/api/v1"
  }
  // Check if we're in a studio context by looking at the URL
  const match = /\/studios\/([^/]+)/.exec(window.location.pathname)
  if (match?.[1] !== undefined) {
    return `/studios/${match[1]}/api/v1`
  }
  return "/api/v1"
}

export const LiveHttpClient = createHttpClient({
  baseUrl: getApiBasePath,
  credentials: "include",
})
