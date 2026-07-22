import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import CommentsController from "./comments_controller"
import MarkdownPreviewController from "./markdown_preview_controller"

// Capture the channel subscription callbacks so tests can simulate a
// server broadcast without a real websocket.
let mockSubscription: { received?: () => void; unsubscribe: () => void } | null = null
let subscribeParams: Record<string, unknown> | null = null

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: (params: Record<string, unknown>, callbacks: { received?: () => void }) => {
        subscribeParams = params
        mockSubscription = { ...callbacks, unsubscribe: vi.fn() }
        return mockSubscription
      },
    },
  }),
}))

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
           data-comments-refresh-url-value="/test-resource/comments.html"
           data-comments-commentable-type-value="Note"
           data-comments-commentable-id-value="resource-1">
        <div class="pulse-section-label">Comments (<span data-comments-target="count">1</span>)</div>
        <div class="pulse-comments-list" data-comments-target="list" data-comment-count="1">
          <div class="pulse-comment" id="n-cmt789">
            Existing comment
            <button class="pulse-comment-reply-btn"
                    data-action="click->comments#startReply"
                    data-comment-path="/n/cmt789"
                    data-comment-author="Bob">Reply</button>
          </div>
        </div>
        <div class="pulse-reply-context-bar" data-comments-target="replyContext" hidden>
          Replying to <strong data-comments-target="replyContextAuthor"></strong>
          <button type="button" data-action="click->comments#cancelReply">x</button>
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
    mockSubscription = null
    subscribeParams = null
  })

  describe("when no composer form is rendered (anonymous or blocked viewer)", () => {
    beforeEach(() => {
      application.stop()
      // Reset state the outer beforeEach set (with a form present), so this
      // block genuinely reflects the new, form-less controller connecting.
      subscribeParams = null
      mockSubscription = null
      // The section still renders with data-controller="comments", but the
      // composer form is absent (logged-out or blocked user).
      document.body.innerHTML = `
        <div class="pulse-comments-section"
             data-controller="comments"
             data-comments-refresh-url-value="/test-resource/comments.html"
             data-comments-commentable-type-value="Note"
             data-comments-commentable-id-value="resource-1">
          <div class="pulse-comments-list" data-comments-target="list">
            <div class="pulse-comment" id="n-cmt789">Existing comment</div>
          </div>
        </div>
      `
      application = Application.start()
      application.register("comments", CommentsController)
    })

    it("connects without throwing and still subscribes for live updates", () => {
      // If connect() read this.formTarget unconditionally it would throw
      // "Missing target element" here and never reach subscribeToChannel.
      expect(subscribeParams).toEqual({
        channel: "CommentsChannel",
        commentable_type: "Note",
        commentable_id: "resource-1",
      })
    })

    it("refreshes on a broadcast even without a composer", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        text: () => Promise.resolve('<div class="pulse-comments-list">Live</div>'),
      })
      vi.stubGlobal("fetch", mockFetch)

      mockSubscription?.received?.()

      await vi.waitFor(() => {
        expect(mockFetch.mock.calls[0][0]).toContain("/test-resource/comments.html")
      })
    })
  })

  describe("live updates via CommentsChannel", () => {
    it("subscribes to the resource's channel on connect", () => {
      expect(subscribeParams).toEqual({
        channel: "CommentsChannel",
        commentable_type: "Note",
        commentable_id: "resource-1",
      })
    })

    it("refreshes the list when the server broadcasts a change", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        text: () => Promise.resolve('<div class="pulse-comments-list">Live</div>'),
      })
      vi.stubGlobal("fetch", mockFetch)

      mockSubscription?.received?.()

      await vi.waitFor(() => {
        expect(mockFetch).toHaveBeenCalled()
        expect(mockFetch.mock.calls[0][0]).toContain("/test-resource/comments.html")
      })
    })

    it("updates the header count from the refreshed list", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        text: () => Promise.resolve('<div class="pulse-comments-list" data-comment-count="5">Live</div>'),
      })
      vi.stubGlobal("fetch", mockFetch)

      mockSubscription?.received?.()

      await vi.waitFor(() => {
        const count = document.querySelector('[data-comments-target="count"]')
        expect(count?.textContent).toBe("5")
      })
    })

    it("serializes overlapping refreshes instead of fetching concurrently", async () => {
      let resolveFirst!: (value: unknown) => void
      const firstResponse = new Promise((resolve) => {
        resolveFirst = resolve
      })
      const mockFetch = vi
        .fn()
        .mockReturnValueOnce(firstResponse)
        .mockResolvedValue({
          ok: true,
          text: () => Promise.resolve('<div class="pulse-comments-list">catch-up</div>'),
        })
      vi.stubGlobal("fetch", mockFetch)

      // Two broadcasts arrive back-to-back while the first refresh is in flight.
      mockSubscription?.received?.()
      mockSubscription?.received?.()

      // Only the first refresh has fired; the second is queued, not racing.
      await Promise.resolve()
      expect(mockFetch).toHaveBeenCalledTimes(1)

      // Completing the first refresh runs exactly one catch-up refresh.
      resolveFirst({
        ok: true,
        text: () => Promise.resolve('<div class="pulse-comments-list">first</div>'),
      })

      await vi.waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(2)
      })
    })
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

  it("resets the markdown editor to Write mode after a successful submit", async () => {
    document.body.innerHTML = `
      <div class="pulse-comments-section"
           data-controller="comments"
           data-comments-refresh-url-value="/test-resource/comments.html">
        <div class="pulse-comments-list" data-comments-target="list"></div>
        <form data-comments-target="form"
              action="/test-resource/comments"
              method="post"
              data-action="submit->comments#submit">
          <div class="pulse-md-editor"
               data-controller="markdown-preview"
               data-markdown-preview-url-value="/markdown/preview">
            <button type="button" data-markdown-preview-target="writeTab"
                    data-action="markdown-preview#showWrite">Write</button>
            <button type="button" data-markdown-preview-target="previewTab"
                    data-action="markdown-preview#showPreview">Preview</button>
            <textarea name="text" data-comments-target="textarea"
                      data-markdown-preview-target="input"></textarea>
            <div data-markdown-preview-target="preview" hidden></div>
          </div>
          <button type="submit" data-comments-target="submitButton">Add Comment</button>
        </form>
      </div>
    `
    application.register("markdown-preview", MarkdownPreviewController)

    const textarea = document.querySelector("textarea") as HTMLTextAreaElement
    const pane = document.querySelector("[data-markdown-preview-target='preview']") as HTMLElement

    // Let both controllers connect (connect() puts the editor in Write mode).
    await vi.waitFor(() => expect(textarea.hidden).toBe(false))

    // Simulate the user having submitted from the Preview tab.
    textarea.hidden = true
    pane.hidden = false

    const mockFetch = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ success: true }) })
      .mockResolvedValueOnce({
        ok: true,
        text: () => Promise.resolve('<div class="pulse-comments-list"></div>'),
      })
    vi.stubGlobal("fetch", mockFetch)

    textarea.value = "Hello"
    document.querySelector("form")!.dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )

    // After a successful submit the editor is back in Write mode.
    await vi.waitFor(() => {
      expect(textarea.hidden).toBe(false)
      expect(pane.hidden).toBe(true)
    })
  })

  describe("startReply and cancelReply", () => {
    it("retargets the composer at the replied-to comment and shows the reply bar", () => {
      const replyBtn = document.querySelector(".pulse-comment-reply-btn") as HTMLElement
      const form = document.querySelector("form") as HTMLFormElement
      const bar = document.querySelector(".pulse-reply-context-bar") as HTMLElement
      const author = document.querySelector("[data-comments-target='replyContextAuthor']") as HTMLElement

      replyBtn.click()

      expect(form.action).toContain("/n/cmt789/comments")
      expect(bar.hidden).toBe(false)
      expect(author.textContent).toBe("Bob")
    })

    it("cancelReply resets the composer to a top-level comment and hides the bar", () => {
      const replyBtn = document.querySelector(".pulse-comment-reply-btn") as HTMLElement
      const form = document.querySelector("form") as HTMLFormElement
      const bar = document.querySelector(".pulse-reply-context-bar") as HTMLElement
      const cancelBtn = bar.querySelector("button") as HTMLElement

      replyBtn.click()
      expect(form.action).toContain("/n/cmt789/comments")

      cancelBtn.click()

      expect(form.action).toContain("/test-resource/comments")
      expect(form.action).not.toContain("/n/cmt789/comments")
      expect(bar.hidden).toBe(true)
    })

    it("resets the reply target back to top-level after a successful submit", async () => {
      const replyBtn = document.querySelector(".pulse-comment-reply-btn") as HTMLElement
      const form = document.querySelector("form") as HTMLFormElement
      const bar = document.querySelector(".pulse-reply-context-bar") as HTMLElement
      const textarea = document.querySelector("textarea") as HTMLTextAreaElement

      replyBtn.click()
      expect(form.action).toContain("/n/cmt789/comments")

      const mockFetch = vi.fn()
        .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ success: true }) })
        .mockResolvedValueOnce({
          ok: true,
          text: () => Promise.resolve('<div class="pulse-comments-list"></div>'),
        })
      vi.stubGlobal("fetch", mockFetch)

      textarea.value = "My reply"
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

      // The POST goes to the reply target...
      await vi.waitFor(() => {
        expect(mockFetch.mock.calls[0][0]).toContain("/n/cmt789/comments")
      })

      // ...then the composer resets to a top-level comment.
      await vi.waitFor(() => {
        expect(bar.hidden).toBe(true)
        expect(form.action).toContain("/test-resource/comments")
        expect(form.action).not.toContain("/n/cmt789/comments")
      })
    })
  })
})
