import { Effect, Context } from "effect"
import {
  NetworkError,
  ApiError,
  NotFoundError,
  UnauthorizedError,
  ValidationError,
  type HttpError,
} from "./errors"
import { getHarmonicContext } from "@/lib/context"

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

/**
 * Get the CSRF token from the Rails-injected window context.
 * Falls back to reading from meta tag if context isn't available.
 */
const getCsrfToken = (): string | undefined => {
  if (typeof window === "undefined") {
    return undefined
  }
  // First try the injected context
  const contextToken = getHarmonicContext().csrfToken
  if (contextToken !== "") {
    return contextToken
  }
  // Fall back to meta tag
  const metaTag = document.querySelector('meta[name="csrf-token"]')
  return metaTag?.getAttribute("content") ?? undefined
}

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
      // Include CSRF token for mutating requests (POST, PUT, PATCH, DELETE)
      const csrfToken = method !== "GET" ? getCsrfToken() : undefined
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
        Accept: "application/json",
        ...(csrfToken !== undefined ? { "X-CSRF-Token": csrfToken } : {}),
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
 * Get the studio-scoped API base path from the current URL.
 * If we're in a studio context (URL includes /studios/{handle}),
 * use the studio-scoped API path.
 * This is called on each request to handle navigation between pages.
 */
const getStudioScopedApiBasePath = (): string => {
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

/**
 * HTTP client for studio-scoped resources (notes, decisions, commitments, cycles).
 * Uses the studio handle from the current URL to scope API requests.
 */
export const LiveHttpClient = createHttpClient({
  baseUrl: getStudioScopedApiBasePath,
  credentials: "include",
})

/**
 * HTTP client for global resources (studios, users).
 * Always uses /api/v1 regardless of current URL.
 */
export const GlobalHttpClient = createHttpClient({
  baseUrl: "/api/v1",
  credentials: "include",
})
