import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { Effect } from "effect"
import { createHttpClient, HttpClient } from "./http"
import type {
  ApiError,
  NetworkError,
  NotFoundError,
  ValidationError,
} from "./errors"

describe("createHttpClient", () => {
  const mockFetch = vi.fn()
  const originalFetch = global.fetch

  beforeEach(() => {
    global.fetch = mockFetch
    mockFetch.mockReset()
  })

  afterEach(() => {
    global.fetch = originalFetch
  })

  const createMockResponse = (status: number, body: unknown) => ({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  })

  describe("successful requests", () => {
    it("makes GET request and returns data", async () => {
      const responseData = { id: 1, name: "Test" }
      mockFetch.mockResolvedValue(createMockResponse(200, responseData))

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.get("/notes")),
        Effect.provideService(HttpClient, client),
      )

      const result = await Effect.runPromise(effect)

      expect(result).toEqual(responseData)
      expect(mockFetch).toHaveBeenCalledWith("/api/v1/notes", {
        method: "GET",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        credentials: "include",
      })
    })

    it("makes POST request with body", async () => {
      const responseData = { id: 1, title: "New Note" }
      mockFetch.mockResolvedValue(createMockResponse(201, responseData))

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.post("/notes", { title: "New Note" })),
        Effect.provideService(HttpClient, client),
      )

      const result = await Effect.runPromise(effect)

      expect(result).toEqual(responseData)
      expect(mockFetch).toHaveBeenCalledWith("/api/v1/notes", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        credentials: "include",
        body: JSON.stringify({ title: "New Note" }),
      })
    })

    it("makes PUT request", async () => {
      mockFetch.mockResolvedValue(createMockResponse(200, { updated: true }))

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.put("/notes/1", { title: "Updated" })),
        Effect.provideService(HttpClient, client),
      )

      await Effect.runPromise(effect)

      expect(mockFetch).toHaveBeenCalledWith(
        "/api/v1/notes/1",
        expect.objectContaining({ method: "PUT" }),
      )
    })

    it("makes PATCH request", async () => {
      mockFetch.mockResolvedValue(createMockResponse(200, { patched: true }))

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.patch("/notes/1", { title: "Patched" })),
        Effect.provideService(HttpClient, client),
      )

      await Effect.runPromise(effect)

      expect(mockFetch).toHaveBeenCalledWith(
        "/api/v1/notes/1",
        expect.objectContaining({ method: "PATCH" }),
      )
    })

    it("makes DELETE request", async () => {
      mockFetch.mockResolvedValue(createMockResponse(204, null))

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.delete("/notes/1")),
        Effect.provideService(HttpClient, client),
      )

      await Effect.runPromise(effect)

      expect(mockFetch).toHaveBeenCalledWith(
        "/api/v1/notes/1",
        expect.objectContaining({ method: "DELETE" }),
      )
    })
  })

  describe("error handling", () => {
    it("returns UnauthorizedError for 401 response", async () => {
      mockFetch.mockResolvedValue(
        createMockResponse(401, { error: "Invalid token" }),
      )

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.get("/notes")),
        Effect.provideService(HttpClient, client),
        Effect.either,
      )

      const result = await Effect.runPromise(effect)

      expect(result._tag).toBe("Left")
      if (result._tag === "Left") {
        expect(result.left._tag).toBe("UnauthorizedError")
      }
    })

    it("returns NotFoundError for 404 response", async () => {
      mockFetch.mockResolvedValue(createMockResponse(404, { error: "Not found" }))

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.get("/notes/123")),
        Effect.provideService(HttpClient, client),
        Effect.either,
      )

      const result = await Effect.runPromise(effect)

      expect(result._tag).toBe("Left")
      if (result._tag === "Left") {
        expect(result.left._tag).toBe("NotFoundError")
        expect((result.left as NotFoundError).resource).toBe("notes")
        expect((result.left as NotFoundError).id).toBe("123")
      }
    })

    it("returns ValidationError for 422 response", async () => {
      const errors = { title: ["is required"] }
      mockFetch.mockResolvedValue(
        createMockResponse(422, { error: "Validation failed", errors }),
      )

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.post("/notes", {})),
        Effect.provideService(HttpClient, client),
        Effect.either,
      )

      const result = await Effect.runPromise(effect)

      expect(result._tag).toBe("Left")
      if (result._tag === "Left") {
        expect(result.left._tag).toBe("ValidationError")
        expect((result.left as ValidationError).errors).toEqual(errors)
      }
    })

    it("returns ValidationError for 400 response", async () => {
      mockFetch.mockResolvedValue(
        createMockResponse(400, { error: "Bad request" }),
      )

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.post("/notes", {})),
        Effect.provideService(HttpClient, client),
        Effect.either,
      )

      const result = await Effect.runPromise(effect)

      expect(result._tag).toBe("Left")
      if (result._tag === "Left") {
        expect(result.left._tag).toBe("ValidationError")
      }
    })

    it("returns ApiError for other error statuses", async () => {
      mockFetch.mockResolvedValue(
        createMockResponse(500, { error: "Internal server error" }),
      )

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.get("/notes")),
        Effect.provideService(HttpClient, client),
        Effect.either,
      )

      const result = await Effect.runPromise(effect)

      expect(result._tag).toBe("Left")
      if (result._tag === "Left") {
        expect(result.left._tag).toBe("ApiError")
        expect((result.left as ApiError).status).toBe(500)
      }
    })

    it("returns NetworkError when fetch throws", async () => {
      mockFetch.mockRejectedValue(new Error("Network failure"))

      const client = createHttpClient({ baseUrl: "/api/v1" })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.get("/notes")),
        Effect.provideService(HttpClient, client),
        Effect.either,
      )

      const result = await Effect.runPromise(effect)

      expect(result._tag).toBe("Left")
      if (result._tag === "Left") {
        expect(result.left._tag).toBe("NetworkError")
        expect((result.left as NetworkError).message).toBe("Network failure")
      }
    })
  })

  describe("configuration", () => {
    it("uses custom credentials setting", async () => {
      mockFetch.mockResolvedValue(createMockResponse(200, {}))

      const client = createHttpClient({
        baseUrl: "/api/v1",
        credentials: "same-origin",
      })
      const effect = HttpClient.pipe(
        Effect.flatMap((http) => http.get("/notes")),
        Effect.provideService(HttpClient, client),
      )

      await Effect.runPromise(effect)

      expect(mockFetch).toHaveBeenCalledWith(
        "/api/v1/notes",
        expect.objectContaining({ credentials: "same-origin" }),
      )
    })
  })
})
