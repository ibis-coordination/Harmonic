import { describe, it, expect } from "vitest"
import {
  NetworkError,
  ApiError,
  NotFoundError,
  UnauthorizedError,
  ValidationError,
} from "./errors"

describe("Functional error types", () => {
  describe("NetworkError", () => {
    it("creates error with message", () => {
      const error = NetworkError({ message: "Connection failed" })
      expect(error.message).toBe("Connection failed")
      expect(error._tag).toBe("NetworkError")
    })

    it("creates error with cause", () => {
      const cause = new Error("Original error")
      const error = NetworkError({
        message: "Connection failed",
        cause,
      })
      expect(error.message).toBe("Connection failed")
      expect(error.cause).toBe(cause)
    })
  })

  describe("ApiError", () => {
    it("creates error with status and message", () => {
      const error = ApiError({
        status: 500,
        message: "Internal server error",
      })
      expect(error.status).toBe(500)
      expect(error.message).toBe("Internal server error")
      expect(error._tag).toBe("ApiError")
    })

    it("creates error with response body", () => {
      const body = { error: "Something went wrong" }
      const error = ApiError({
        status: 500,
        message: "Internal server error",
        body,
      })
      expect(error.body).toEqual(body)
    })
  })

  describe("NotFoundError", () => {
    it("creates error with resource and id", () => {
      const error = NotFoundError({
        resource: "note",
        id: "abc123",
      })
      expect(error.resource).toBe("note")
      expect(error.id).toBe("abc123")
      expect(error._tag).toBe("NotFoundError")
    })
  })

  describe("UnauthorizedError", () => {
    it("creates error with message", () => {
      const error = UnauthorizedError({
        message: "Invalid token",
      })
      expect(error.message).toBe("Invalid token")
      expect(error._tag).toBe("UnauthorizedError")
    })
  })

  describe("ValidationError", () => {
    it("creates error with message", () => {
      const error = ValidationError({
        message: "Validation failed",
      })
      expect(error.message).toBe("Validation failed")
      expect(error._tag).toBe("ValidationError")
    })

    it("creates error with field errors", () => {
      const errors = {
        title: ["is required", "must be at least 3 characters"],
        text: ["cannot be empty"],
      }
      const error = ValidationError({
        message: "Validation failed",
        errors,
      })
      expect(error.errors).toEqual(errors)
    })
  })

  describe("error discrimination", () => {
    it("can discriminate between error types using _tag", () => {
      const errors = [
        NetworkError({ message: "Network error" }),
        ApiError({ status: 500, message: "Server error" }),
        NotFoundError({ resource: "note", id: "123" }),
        UnauthorizedError({ message: "Unauthorized" }),
        ValidationError({ message: "Invalid" }),
      ]

      const tags = errors.map((e) => e._tag)
      expect(tags).toEqual([
        "NetworkError",
        "ApiError",
        "NotFoundError",
        "UnauthorizedError",
        "ValidationError",
      ])
    })
  })
})
