import { Effect, Layer } from "effect"
import { HttpClient, LiveHttpClient } from "./http"
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
  ): Effect.Effect<Note, HttpError, HttpClient> =>
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
  }): Effect.Effect<Note, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post<Note>("/notes", { note: data }),
    ),

  update: (
    id: string,
    data: { title?: string; text?: string; deadline?: string },
  ): Effect.Effect<Note, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.patch<Note>(`/notes/${id}`, data),
    ),

  confirmRead: (id: string): Effect.Effect<unknown, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post(`/notes/${id}/confirm`),
    ),
}

export const DecisionsService = {
  create: (data: {
    title?: string
    text: string
    deadline?: string
    options: string[]
  }): Effect.Effect<Decision, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post<Decision>("/decisions", { decision: data }),
    ),

  vote: (
    decisionId: string,
    votes: { option_id: number; rank: number }[],
  ): Effect.Effect<unknown, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post(`/decisions/${decisionId}/votes`, { votes }),
    ),
}

export const CommitmentsService = {
  create: (data: {
    title?: string
    text: string
    critical_mass: number
    deadline?: string
  }): Effect.Effect<Commitment, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post<Commitment>("/commitments", { commitment: data }),
    ),

  join: (id: string): Effect.Effect<unknown, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.post(`/commitments/${id}/join`),
    ),
}

export const CyclesService = {
  get: (
    name: string,
    options?: { include?: ("notes" | "decisions" | "commitments")[] },
  ): Effect.Effect<Cycle, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) => {
      const params = new URLSearchParams()
      if (options?.include) {
        params.set("include", options.include.join(","))
      }
      const query = params.toString()
      return client.get<Cycle>(`/cycles/${name}${query ? `?${query}` : ""}`)
    }),
}

export const UsersService = {
  list: (): Effect.Effect<User[], HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.get<User[]>("/users"),
    ),

  me: (): Effect.Effect<User, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.get<User>("/users/me"),
    ),
}

export const StudiosService = {
  list: (): Effect.Effect<Studio[], HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.get<Studio[]>("/studios"),
    ),

  get: (handle: string): Effect.Effect<Studio, HttpError, HttpClient> =>
    Effect.flatMap(HttpClient, (client) =>
      client.get<Studio>(`/studios/${handle}`),
    ),
}

export const HttpClientLive = Layer.succeed(HttpClient, LiveHttpClient)

export function runApiEffect<A, E>(
  effect: Effect.Effect<A, E, HttpClient>,
): Promise<A> {
  return Effect.runPromise(Effect.provide(effect, HttpClientLive))
}
