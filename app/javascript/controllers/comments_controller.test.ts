import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import CommentsController from "./comments_controller"

describe("CommentsController", () => {
  let application: Application

  beforeEach(() => {
    // Set up CSRF meta tag
    document.head.innerHTML = `
      <meta name="csrf-token" content="test-csrf-token">
    `

    // Set up DOM with comment form
    document.body.innerHTML = `
      <div class="pulse-comments-section"
           data-controller="comments"
           data-comments-refresh-url-value="/test-resource/comments.html">
        <div class="pulse-comments-list" data-comments-target="list">
          <div class="pulse-comment">Existing comment</div>
        </div>
        <form data-comments-target="form"
              action="/test-resource/comments"
              method="post"
              data-action="submit->comments#submit">
          <textarea name="text" data-comments-target="textarea"></textarea>
          <button type="submit" data-comments-target="submitButton">Add Comment</button>
        </form>
      </div>
    `

    application = Application.start()
    application.register("comments", CommentsController)
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("initializes with form and list targets", () => {
    const form = document.querySelector("[data-comments-target='form']")
    const list = document.querySelector("[data-comments-target='list']")
    expect(form).toBeDefined()
    expect(list).toBeDefined()
  })

  it("prevents submission with empty text", async () => {
    const mockFetch = vi.fn()
    vi.stubGlobal("fetch", mockFetch)

    const form = document.querySelector("form") as HTMLFormElement
    const submitEvent = new Event("submit", { bubbles: true, cancelable: true })

    form.dispatchEvent(submitEvent)

    // Should not call fetch if text is empty
    expect(mockFetch).not.toHaveBeenCalled()
  })

  it("submits comment via fetch and refreshes list", async () => {
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ success: true }),
      })
      .mockResolvedValueOnce({
        ok: true,
        text: () => Promise.resolve('<div class="pulse-comments-list">New comments</div>'),
      })
    vi.stubGlobal("fetch", mockFetch)

    const form = document.querySelector("form") as HTMLFormElement
    const textarea = document.querySelector("textarea") as HTMLTextAreaElement

    textarea.value = "Test comment"
    const submitEvent = new Event("submit", { bubbles: true, cancelable: true })
    form.dispatchEvent(submitEvent)

    // Wait for async operations - check that first call is the POST
    await vi.waitFor(() => {
      expect(mockFetch).toHaveBeenCalled()
      // URL may include full origin in jsdom, so use toContain
      expect(mockFetch.mock.calls[0][0]).toContain("/test-resource/comments")
    })

    // First call should be the POST to create comment
    expect(mockFetch.mock.calls[0][1].method).toBe("POST")
    expect(mockFetch.mock.calls[0][1].headers["X-CSRF-Token"]).toBe("test-csrf-token")

    // Wait for refresh call
    await vi.waitFor(() => {
      expect(mockFetch.mock.calls.length).toBeGreaterThanOrEqual(2)
    })

    // Second call should be the refresh
    expect(mockFetch.mock.calls[1][0]).toContain("/test-resource/comments.html")
  })

  it("clears textarea after successful submission", async () => {
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ success: true }),
      })
      .mockResolvedValueOnce({
        ok: true,
        text: () => Promise.resolve('<div class="pulse-comments-list">New comments</div>'),
      })
    vi.stubGlobal("fetch", mockFetch)

    const form = document.querySelector("form") as HTMLFormElement
    const textarea = document.querySelector("textarea") as HTMLTextAreaElement

    textarea.value = "Test comment"
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

    await vi.waitFor(() => {
      expect(textarea.value).toBe("")
    })
  })

  it("shows loading state during submission", async () => {
    // Use a promise we can control to test loading state
    let resolveSubmit: () => void
    const submitPromise = new Promise<void>((resolve) => {
      resolveSubmit = resolve
    })

    const mockFetch = vi.fn().mockImplementationOnce(() =>
      submitPromise.then(() => ({
        ok: true,
        json: () => Promise.resolve({ success: true }),
      }))
    )
    vi.stubGlobal("fetch", mockFetch)

    const form = document.querySelector("form") as HTMLFormElement
    const textarea = document.querySelector("textarea") as HTMLTextAreaElement
    const submitButton = document.querySelector("[data-comments-target='submitButton']") as HTMLButtonElement

    textarea.value = "Test comment"
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

    // Check loading state
    await vi.waitFor(() => {
      expect(submitButton.disabled).toBe(true)
      expect(submitButton.textContent).toBe("Adding...")
    })

    // Resolve and check final state
    resolveSubmit!()
  })

  it("prevents double submission", async () => {
    // Use a promise we can control
    let resolveSubmit: () => void
    const submitPromise = new Promise<void>((resolve) => {
      resolveSubmit = resolve
    })

    const mockFetch = vi.fn().mockImplementation(() =>
      submitPromise.then(() => ({
        ok: true,
        json: () => Promise.resolve({ success: true }),
      }))
    )
    vi.stubGlobal("fetch", mockFetch)

    const form = document.querySelector("form") as HTMLFormElement
    const textarea = document.querySelector("textarea") as HTMLTextAreaElement

    textarea.value = "Test comment"

    // Submit twice quickly
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

    // Wait a tick to let any async code run
    await new Promise(resolve => setTimeout(resolve, 0))

    // Only one fetch call should have been made (second submit should be blocked by isSubmitting)
    expect(mockFetch).toHaveBeenCalledTimes(1)

    resolveSubmit!()
  })

  it("handles fetch error gracefully", async () => {
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const mockFetch = vi.fn().mockRejectedValue(new Error("Network error"))
    vi.stubGlobal("fetch", mockFetch)

    const form = document.querySelector("form") as HTMLFormElement
    const textarea = document.querySelector("textarea") as HTMLTextAreaElement
    const submitButton = document.querySelector("[data-comments-target='submitButton']") as HTMLButtonElement

    textarea.value = "Test comment"
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

    await vi.waitFor(() => {
      expect(consoleSpy).toHaveBeenCalled()
      // Button should be re-enabled after error
      expect(submitButton.disabled).toBe(false)
    })
  })

  describe("getExpandedThreadIds and restoreExpandedThreads", () => {
    beforeEach(() => {
      document.body.innerHTML = `
        <div class="pulse-comments-section"
             data-controller="comments"
             data-comments-refresh-url-value="/test-resource/comments.html">
          <div class="pulse-comments-list" data-comments-target="list">
            <button class="pulse-replies-toggle" data-thread-id="abc123" data-reply-count="2">
              <span class="pulse-replies-toggle-text">2 replies</span>
            </button>
            <div id="replies-abc123" hidden>Replies here</div>
            <button class="pulse-replies-toggle is-collapsed" data-thread-id="def456" data-reply-count="1">
              <span class="pulse-replies-toggle-text">1 reply</span>
            </button>
            <div id="replies-def456" hidden>Replies here</div>
          </div>
          <form data-comments-target="form" action="/test-resource/comments" method="post">
            <textarea name="text" data-comments-target="textarea"></textarea>
            <button type="submit" data-comments-target="submitButton">Add Comment</button>
          </form>
        </div>
      `
      application = Application.start()
      application.register("comments", CommentsController)
    })

    it("preserves expanded threads after refresh", async () => {
      // First, manually expand thread abc123
      const toggleBtn = document.querySelector('.pulse-replies-toggle[data-thread-id="abc123"]') as HTMLElement
      toggleBtn.classList.remove("is-collapsed")
      const repliesContainer = document.getElementById("replies-abc123") as HTMLElement
      repliesContainer.hidden = false

      // Mock fetch for refresh
      const mockFetch = vi.fn()
        .mockResolvedValueOnce({
          ok: true,
          json: () => Promise.resolve({ success: true }),
        })
        .mockResolvedValueOnce({
          ok: true,
          text: () => Promise.resolve(`
            <div class="pulse-comments-list">
              <button class="pulse-replies-toggle is-collapsed" data-thread-id="abc123" data-reply-count="3">
                <span class="pulse-replies-toggle-text">3 replies</span>
              </button>
              <div id="replies-abc123" hidden>New replies</div>
            </div>
          `),
        })
      vi.stubGlobal("fetch", mockFetch)

      const form = document.querySelector("form") as HTMLFormElement
      const textarea = document.querySelector("textarea") as HTMLTextAreaElement
      textarea.value = "New comment"
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

      await vi.waitFor(() => {
        // After refresh, the thread should still be expanded
        const newRepliesContainer = document.getElementById("replies-abc123") as HTMLElement
        expect(newRepliesContainer.hidden).toBe(false)
      })
    })
  })
})
