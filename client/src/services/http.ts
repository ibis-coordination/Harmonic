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
  baseUrl: string
  credentials?: RequestCredentials
}

export class HttpClient extends Context.Tag("HttpClient")<
  HttpClient,
  {
    get: <T>(path: string) => Effect.Effect<T, HttpError>
    post: <T>(path: string, body?: unknown) => Effect.Effect<T, HttpError>
    put: <T>(path: string, body?: unknown) => Effect.Effect<T, HttpError>
    patch: <T>(path: string, body?: unknown) => Effect.Effect<T, HttpError>
    delete: <T>(path: string) => Effect.Effect<T, HttpError>
  }
>() {}

function mapStatusToError(
  status: number,
  body: unknown,
  path: string,
): HttpError {
  if (status === 401) {
    return new UnauthorizedError({
      message:
        typeof body === "object" && body !== null && "error" in body
          ? String((body as { error: unknown }).error)
          : "Unauthorized",
    })
  }
  if (status === 404) {
    return new NotFoundError({
      resource: path.split("/")[1] ?? "resource",
      id: path.split("/")[2] ?? "",
    })
  }
  if (status === 422 || status === 400) {
    const errors =
      typeof body === "object" && body !== null && "errors" in body
        ? (body as { errors: Record<string, string[]> }).errors
        : undefined
    return new ValidationError({
      message:
        typeof body === "object" && body !== null && "error" in body
          ? String((body as { error: unknown }).error)
          : "Validation failed",
      ...(errors !== undefined ? { errors } : {}),
    })
  }
  return new ApiError({
    status,
    message: `API request failed with status ${status}`,
    body,
  })
}

export function createHttpClient(config: HttpClientConfig) {
  const request = <T>(
    method: string,
    path: string,
    body?: unknown,
  ): Effect.Effect<T, HttpError> =>
    Effect.tryPromise({
      try: async () => {
        const url = `${config.baseUrl}${path}`
        const fetchOptions: RequestInit = {
          method,
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          credentials: config.credentials ?? "include",
        }
        if (body !== undefined) {
          fetchOptions.body = JSON.stringify(body)
        }
        const response = await fetch(url, fetchOptions)

        const responseBody = (await response.json().catch(() => null)) as T

        if (!response.ok) {
          throw mapStatusToError(response.status, responseBody, path)
        }

        return responseBody
      },
      catch: (error) => {
        if (
          error instanceof NetworkError ||
          error instanceof ApiError ||
          error instanceof NotFoundError ||
          error instanceof UnauthorizedError ||
          error instanceof ValidationError
        ) {
          return error
        }
        return new NetworkError({
          message: error instanceof Error ? error.message : "Network error",
          cause: error,
        })
      },
    })

  return HttpClient.of({
    get: <T>(path: string) => request<T>("GET", path),
    post: <T>(path: string, body?: unknown) => request<T>("POST", path, body),
    put: <T>(path: string, body?: unknown) => request<T>("PUT", path, body),
    patch: <T>(path: string, body?: unknown) => request<T>("PATCH", path, body),
    delete: <T>(path: string) => request<T>("DELETE", path),
  })
}

export const LiveHttpClient = createHttpClient({
  baseUrl: "/api/v1",
  credentials: "include",
})
