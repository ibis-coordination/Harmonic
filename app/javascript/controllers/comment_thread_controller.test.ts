import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import CommentThreadController from "./comment_thread_controller"

describe("CommentThreadController", () => {
  let application: Application

  beforeEach(() => {
    // Set up CSRF meta tag
    document.head.innerHTML = `
      <meta name="csrf-token" content="test-csrf-token">
    `

    // Flat comment list: every comment is a sibling, no nested reply groups.
    document.body.innerHTML = `
      <div class="pulse-comments-section" data-comments-refresh-url-value="/test-resource/comments.html">
        <div class="pulse-comments-list" data-controller="comment-thread">
          <div class="pulse-comment" id="n-abc123">
            <div class="pulse-comment-body">Top level comment</div>
          </div>
          <div class="pulse-comment" id="n-def456">
            <div class="pulse-comment-body">A reply</div>
          </div>
          <div class="pulse-confirm-read-btn"
               data-action="click->comment-thread#confirmRead"
               data-comment-path="/n/abc123">
            <span class="pulse-confirm-count">0</span>
          </div>
        </div>
      </div>
    `

    application = Application.start()
    application.register("comment-thread", CommentThreadController)
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    window.history.replaceState({}, "", "/")
  })

  describe("highlightCommentFromUrl", () => {
    // Reconnect a fresh controller after pointing the URL at a comment, since
    // the shared beforeEach already connected with a comment_id-less URL.
    const reconnect = (): void => {
      application.stop()
      application = Application.start()
      application.register("comment-thread", CommentThreadController)
    }

    beforeEach(() => {
      // jsdom doesn't implement scrollIntoView, so define a no-op stub the
      // highlight path can call.
      Element.prototype.scrollIntoView = vi.fn()
    })

    it("highlights the targeted comment and clears the comment_id param", async () => {
      window.history.replaceState({}, "", "/test-resource?comment_id=def456")
      reconnect()

      const target = document.getElementById("n-def456") as HTMLElement
      await vi.waitFor(() => {
        expect(target.classList.contains("pulse-comment-highlighted")).toBe(true)
      })

      // The param is dropped so reconnects won't re-highlight.
      expect(window.location.search).toBe("")
    })

    it("preserves other query params and the hash when clearing comment_id", async () => {
      window.history.replaceState({}, "", "/test-resource?foo=bar&comment_id=def456#section")
      reconnect()

      const target = document.getElementById("n-def456") as HTMLElement
      await vi.waitFor(() => {
        expect(target.classList.contains("pulse-comment-highlighted")).toBe(true)
      })

      expect(window.location.search).toBe("?foo=bar")
      expect(window.location.hash).toBe("#section")
    })

    it("does not re-highlight when the controller reconnects after a reply", async () => {
      window.history.replaceState({}, "", "/test-resource?comment_id=def456")
      reconnect()

      const target = document.getElementById("n-def456") as HTMLElement
      await vi.waitFor(() => {
        expect(target.classList.contains("pulse-comment-highlighted")).toBe(true)
      })

      // Simulate the post-reply refresh: clear the visual highlight and
      // reconnect a fresh controller (as replaceWith does in the real flow).
      target.classList.remove("pulse-comment-highlighted")
      reconnect()

      await new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve))
      )
      expect(target.classList.contains("pulse-comment-highlighted")).toBe(false)
    })

    it("does nothing when comment_id is absent", async () => {
      window.history.replaceState({}, "", "/test-resource")
      reconnect()

      await new Promise((resolve) => requestAnimationFrame(resolve))
      const highlighted = document.querySelector(".pulse-comment-highlighted")
      expect(highlighted).toBeNull()
    })
  })

  describe("confirmRead", () => {
    it("sends confirm read request and updates UI", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ confirmed_reads: 5 }),
      })
      vi.stubGlobal("fetch", mockFetch)

      const confirmBtn = document.querySelector(".pulse-confirm-read-btn") as HTMLElement
      const countSpan = confirmBtn.querySelector(".pulse-confirm-count") as HTMLElement

      confirmBtn.click()

      await vi.waitFor(() => {
        expect(mockFetch).toHaveBeenCalledWith(
          "/n/abc123/actions/confirm_read",
          expect.objectContaining({
            method: "POST",
            headers: expect.objectContaining({
              "X-CSRF-Token": "test-csrf-token",
            }),
          })
        )
        expect(confirmBtn.classList.contains("is-confirmed")).toBe(true)
        expect(countSpan.textContent).toBe("5")
      })
    })

    it("prevents double-click", async () => {
      let resolveRequest: () => void
      const requestPromise = new Promise<void>((resolve) => {
        resolveRequest = resolve
      })

      const mockFetch = vi.fn().mockImplementation(() =>
        requestPromise.then(() => ({
          ok: true,
          json: () => Promise.resolve({ confirmed_reads: 1 }),
        }))
      )
      vi.stubGlobal("fetch", mockFetch)

      const confirmBtn = document.querySelector(".pulse-confirm-read-btn") as HTMLElement

      // Click twice quickly
      confirmBtn.click()
      confirmBtn.click()

      // Only one fetch should have been made
      expect(mockFetch).toHaveBeenCalledTimes(1)

      resolveRequest!()
    })

    it("does not re-trigger on already confirmed button", async () => {
      const mockFetch = vi.fn()
      vi.stubGlobal("fetch", mockFetch)

      const confirmBtn = document.querySelector(".pulse-confirm-read-btn") as HTMLElement
      confirmBtn.classList.add("is-confirmed")

      confirmBtn.click()

      expect(mockFetch).not.toHaveBeenCalled()
    })

    it("shows loading state during request", async () => {
      let resolveRequest: () => void
      const requestPromise = new Promise<void>((resolve) => {
        resolveRequest = resolve
      })

      const mockFetch = vi.fn().mockImplementation(() =>
        requestPromise.then(() => ({
          ok: true,
          json: () => Promise.resolve({ confirmed_reads: 1 }),
        }))
      )
      vi.stubGlobal("fetch", mockFetch)

      const confirmBtn = document.querySelector(".pulse-confirm-read-btn") as HTMLElement

      confirmBtn.click()

      await vi.waitFor(() => {
        expect(confirmBtn.classList.contains("is-loading")).toBe(true)
      })

      resolveRequest!()

      await vi.waitFor(() => {
        expect(confirmBtn.classList.contains("is-loading")).toBe(false)
      })
    })
  })
})
