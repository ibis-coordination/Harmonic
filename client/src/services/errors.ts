// Functional error types using tagged unions

export interface NetworkError {
  readonly _tag: "NetworkError"
  readonly message: string
  readonly cause?: unknown
}

export interface ApiError {
  readonly _tag: "ApiError"
  readonly status: number
  readonly message: string
  readonly body?: unknown
}

export interface NotFoundError {
  readonly _tag: "NotFoundError"
  readonly resource: string
  readonly id: string
}

export interface UnauthorizedError {
  readonly _tag: "UnauthorizedError"
  readonly message: string
}

export interface ValidationError {
  readonly _tag: "ValidationError"
  readonly message: string
  readonly errors?: Record<string, readonly string[]>
}

export type HttpError =
  | NetworkError
  | ApiError
  | NotFoundError
  | UnauthorizedError
  | ValidationError

// Constructor functions
export const NetworkError = (params: Omit<NetworkError, "_tag">): NetworkError => ({
  _tag: "NetworkError",
  ...params,
})

export const ApiError = (params: Omit<ApiError, "_tag">): ApiError => ({
  _tag: "ApiError",
  ...params,
})

export const NotFoundError = (params: Omit<NotFoundError, "_tag">): NotFoundError => ({
  _tag: "NotFoundError",
  ...params,
})

export const UnauthorizedError = (params: Omit<UnauthorizedError, "_tag">): UnauthorizedError => ({
  _tag: "UnauthorizedError",
  ...params,
})

export const ValidationError = (params: Omit<ValidationError, "_tag">): ValidationError => ({
  _tag: "ValidationError",
  ...params,
})

// Type guards
export const isNetworkError = (error: HttpError): error is NetworkError =>
  error._tag === "NetworkError"

export const isApiError = (error: HttpError): error is ApiError =>
  error._tag === "ApiError"

export const isNotFoundError = (error: HttpError): error is NotFoundError =>
  error._tag === "NotFoundError"

export const isUnauthorizedError = (error: HttpError): error is UnauthorizedError =>
  error._tag === "UnauthorizedError"

export const isValidationError = (error: HttpError): error is ValidationError =>
  error._tag === "ValidationError"
