import { Data } from "effect"

export class NetworkError extends Data.TaggedError("NetworkError")<{
  message: string
  cause?: unknown
}> {}

export class ApiError extends Data.TaggedError("ApiError")<{
  status: number
  message: string
  body?: unknown
}> {}

export class NotFoundError extends Data.TaggedError("NotFoundError")<{
  resource: string
  id: string
}> {}

export class UnauthorizedError extends Data.TaggedError("UnauthorizedError")<{
  message: string
}> {}

export class ValidationError extends Data.TaggedError("ValidationError")<{
  message: string
  errors?: Record<string, string[]>
}> {}

export type HttpError =
  | NetworkError
  | ApiError
  | NotFoundError
  | UnauthorizedError
  | ValidationError
