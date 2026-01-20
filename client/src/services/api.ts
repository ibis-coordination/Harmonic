import { Effect, Layer } from "effect"
import {
  HttpClient,
  LiveHttpClient,
  GlobalHttpClient,
  type HttpClientService,
} from "./http"
import type { HttpError } from "./errors"
import type {
  Note,
  Decision,
  Commitment,
  Cycle,
  User,
  Studio,
} from "./types"

export const NotesService = {
  get: (
    id: string,
    options?: { include?: ("history_events" | "backlinks")[] },
  ): Effect.Effect<Note, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) => {
      const params = new URLSearchParams()
      if (options?.include) {
        params.set("include", options.include.join(","))
      }
      const query = params.toString()
      return client.get<Note>(`/notes/${id}${query ? `?${query}` : ""}`)
    }),

  create: (data: {
    title?: string
    text: string
    deadline?: string
  }): Effect.Effect<Note, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) => client.post<Note>("/notes", data)),

  update: (
    id: string,
    data: { title?: string; text?: string; deadline?: string },
  ): Effect.Effect<Note, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) =>
      client.patch<Note>(`/notes/${id}`, data),
    ),

  confirmRead: (id: string): Effect.Effect<unknown, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post(`/notes/${id}/confirm`),
    ),
}

export const DecisionsService = {
  get: (
    id: string,
    options?: {
      include?: ("options" | "participants" | "votes" | "results" | "backlinks")[]
    },
  ): Effect.Effect<Decision, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) => {
      const params = new URLSearchParams()
      if (options?.include) {
        params.set("include", options.include.join(","))
      }
      const query = params.toString()
      return client.get<Decision>(`/decisions/${id}${query ? `?${query}` : ""}`)
    }),

  create: (data: {
    question: string
    description?: string
    deadline?: string
    options_open?: boolean
  }): Effect.Effect<Decision, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post<Decision>("/decisions", data),
    ),

  addOption: (
    decisionId: string,
    data: { title: string; description?: string },
  ): Effect.Effect<unknown, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post(`/decisions/${decisionId}/options`, data),
    ),

  vote: (
    decisionId: string,
    optionId: number,
    data: { accepted: 0 | 1; preferred: 0 | 1 },
  ): Effect.Effect<unknown, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post(
        `/decisions/${decisionId}/options/${String(optionId)}/votes`,
        data,
      ),
    ),
}

export const CommitmentsService = {
  create: (data: {
    title?: string
    text: string
    critical_mass: number
    deadline?: string
  }): Effect.Effect<Commitment, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post<Commitment>("/commitments", data),
    ),

  join: (id: string): Effect.Effect<unknown, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post(`/commitments/${id}/join`),
    ),
}

export const CyclesService = {
  get: (
    name: string,
    options?: { include?: ("notes" | "decisions" | "commitments")[] },
  ): Effect.Effect<Cycle, HttpError, HttpClientService> =>
    Effect.flatMap(HttpClient, (client) => {
      const params = new URLSearchParams()
      if (options?.include) {
        params.set("include", options.include.join(","))
      }
      const query = params.toString()
      return client.get<Cycle>(`/cycles/${name}${query ? `?${query}` : ""}`)
    }),
}

// Global resources use GlobalHttpClient (not studio-scoped)
export const UsersService = {
  list: (): Effect.Effect<User[], HttpError> => GlobalHttpClient.get<User[]>("/users"),

  me: (): Effect.Effect<User, HttpError> => GlobalHttpClient.get<User>("/users/me"),
}

// Global resources use GlobalHttpClient (not studio-scoped)
export const StudiosService = {
  list: (): Effect.Effect<Studio[], HttpError> =>
    GlobalHttpClient.get<Studio[]>("/studios"),

  get: (handle: string): Effect.Effect<Studio, HttpError> =>
    GlobalHttpClient.get<Studio>(`/studios/${handle}`),
}

export const HttpClientLive: Layer.Layer<HttpClientService> = Layer.succeed(
  HttpClient,
  LiveHttpClient,
)

/**
 * Run an API effect. Handles both studio-scoped effects (that require HttpClientService)
 * and global effects (that don't require any service).
 */
export const runApiEffect = <A, E>(
  effect: Effect.Effect<A, E, HttpClientService> | Effect.Effect<A, E>,
): Promise<A> => {
  // Provide the HttpClientService layer for studio-scoped resources
  const providedEffect = Effect.provide(
    effect as Effect.Effect<A, E, HttpClientService>,
    HttpClientLive,
  )
  return Effect.runPromise(providedEffect)
}
