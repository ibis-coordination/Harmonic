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

    // Set up DOM with comment thread structure
    document.body.innerHTML = `
      <div class="pulse-comments-section" data-comments-refresh-url-value="/test-resource/comments.html">
        <div class="pulse-comments-list" data-controller="comment-thread">
          <div class="pulse-comment" id="n-abc123">
            <div class="pulse-comment-body">Top level comment</div>
            <button class="pulse-comment-reply-btn"
                    data-action="click->comment-thread#showReplyForm"
                    data-comment-id="abc123"
                    data-root-comment-id="abc123">
              Reply
            </button>
          </div>
          <button class="pulse-replies-toggle is-collapsed"
                  data-action="click->comment-thread#toggleReplies"
                  data-thread-id="abc123"
                  data-reply-count="2"
                  aria-expanded="false"
                  aria-controls="replies-abc123">
            <span class="pulse-replies-toggle-text">2 replies</span>
          </button>
          <div class="pulse-comment-replies" id="replies-abc123" hidden>
            <div class="pulse-comment" id="n-def456">
              <div class="pulse-comment-body">Nested reply</div>
              <button class="pulse-comment-reply-btn"
                      data-action="click->comment-thread#showReplyForm"
                      data-comment-id="def456"
                      data-root-comment-id="abc123">
                Reply
              </button>
            </div>
          </div>
          <div class="pulse-reply-form-container" id="reply-form-abc123" hidden>
            <form action="/n/abc123/comments"
                  method="post"
                  data-action="submit->comment-thread#submitReply">
              <input type="hidden" id="reply-to-abc123" name="reply_to" value="abc123">
              <textarea name="text" placeholder="Write a reply..."></textarea>
              <button type="button"
                      class="pulse-btn-secondary"
                      data-action="click->comment-thread#hideReplyForm">
                Cancel
              </button>
              <button type="submit">Reply</button>
            </form>
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
  })

  describe("toggleReplies", () => {
    it("expands collapsed replies", async () => {
      // Wait for Stimulus to connect
      await vi.waitFor(() => {
        const controllerElement = document.querySelector("[data-controller='comment-thread']")
        return controllerElement !== null
      })

      const toggleBtn = document.querySelector(".pulse-replies-toggle") as HTMLElement
      const repliesContainer = document.getElementById("replies-abc123") as HTMLElement
      const textSpan = toggleBtn.querySelector(".pulse-replies-toggle-text") as HTMLElement

      expect(repliesContainer.hidden).toBe(true)
      expect(toggleBtn.classList.contains("is-collapsed")).toBe(true)

      toggleBtn.click()

      expect(repliesContainer.hidden).toBe(false)
      expect(toggleBtn.classList.contains("is-collapsed")).toBe(false)
      expect(toggleBtn.getAttribute("aria-expanded")).toBe("true")
      expect(textSpan.textContent).toBe("Hide replies")
    })

    it("collapses expanded replies", async () => {
      await vi.waitFor(() => {
        const controllerElement = document.querySelector("[data-controller='comment-thread']")
        return controllerElement !== null
      })

      const toggleBtn = document.querySelector(".pulse-replies-toggle") as HTMLElement
      const repliesContainer = document.getElementById("replies-abc123") as HTMLElement
      const textSpan = toggleBtn.querySelector(".pulse-replies-toggle-text") as HTMLElement

      // First expand - set state manually to avoid timing issues
      repliesContainer.hidden = false
      toggleBtn.classList.remove("is-collapsed")
      toggleBtn.setAttribute("aria-expanded", "true")
      textSpan.textContent = "Hide replies"

      // Then collapse via click
      toggleBtn.click()

      expect(repliesContainer.hidden).toBe(true)
      expect(toggleBtn.classList.contains("is-collapsed")).toBe(true)
      expect(toggleBtn.getAttribute("aria-expanded")).toBe("false")
      expect(textSpan.textContent).toBe("2 replies")
    })

    it("handles singular reply count", async () => {
      await vi.waitFor(() => {
        const controllerElement = document.querySelector("[data-controller='comment-thread']")
        return controllerElement !== null
      })

      const toggleBtn = document.querySelector(".pulse-replies-toggle") as HTMLElement
      const textSpan = toggleBtn.querySelector(".pulse-replies-toggle-text") as HTMLElement

      // Change to 1 reply
      toggleBtn.dataset.replyCount = "1"
      textSpan.textContent = "1 reply"

      // Expand
      toggleBtn.click()
      expect(textSpan.textContent).toBe("Hide reply")

      // Set expanded state for collapse test
      const repliesContainer = document.getElementById("replies-abc123") as HTMLElement
      repliesContainer.hidden = false

      // Collapse
      toggleBtn.click()
      expect(textSpan.textContent).toBe("1 reply")
    })
  })

  describe("showReplyForm", () => {
    it("shows reply form for top-level comment", () => {
      const replyBtn = document.querySelector('[data-comment-id="abc123"]') as HTMLElement
      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement

      expect(formContainer.hidden).toBe(true)

      replyBtn.click()

      expect(formContainer.hidden).toBe(false)
    })

    it("updates form action when replying to nested comment", () => {
      const nestedReplyBtn = document.querySelector('[data-comment-id="def456"]') as HTMLElement
      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement
      const form = formContainer.querySelector("form") as HTMLFormElement
      const hiddenInput = document.getElementById("reply-to-abc123") as HTMLInputElement

      nestedReplyBtn.click()

      // Form action should point to the nested comment
      expect(form.action).toContain("/n/def456/comments")
      expect(hiddenInput.value).toBe("def456")
    })

    it("hides other open reply forms", () => {
      // Add another reply form container
      const list = document.querySelector(".pulse-comments-list") as HTMLElement
      const anotherForm = document.createElement("div")
      anotherForm.className = "pulse-reply-form-container"
      anotherForm.id = "reply-form-xyz789"
      anotherForm.hidden = false // This one is open
      list.appendChild(anotherForm)

      const replyBtn = document.querySelector('[data-comment-id="abc123"]') as HTMLElement
      replyBtn.click()

      expect(anotherForm.hidden).toBe(true)
      expect(document.getElementById("reply-form-abc123")?.hidden).toBe(false)
    })

    it("focuses textarea when form is shown", () => {
      const replyBtn = document.querySelector('[data-comment-id="abc123"]') as HTMLElement
      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement
      const textarea = formContainer.querySelector("textarea") as HTMLTextAreaElement

      // Mock focus
      const focusSpy = vi.spyOn(textarea, "focus")

      replyBtn.click()

      expect(focusSpy).toHaveBeenCalled()
    })
  })

  describe("hideReplyForm", () => {
    it("hides form and clears textarea", () => {
      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement
      const cancelBtn = formContainer.querySelector('[data-action="click->comment-thread#hideReplyForm"]') as HTMLElement
      const textarea = formContainer.querySelector("textarea") as HTMLTextAreaElement

      formContainer.hidden = false
      textarea.value = "Draft reply"

      cancelBtn.click()

      expect(formContainer.hidden).toBe(true)
      expect(textarea.value).toBe("")
    })
  })

  describe("submitReply", () => {
    it("prevents submission with empty text", async () => {
      const mockFetch = vi.fn()
      vi.stubGlobal("fetch", mockFetch)

      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement
      const form = formContainer.querySelector("form") as HTMLFormElement

      formContainer.hidden = false
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

      expect(mockFetch).not.toHaveBeenCalled()
    })

    it("submits reply via fetch", async () => {
      const mockFetch = vi.fn()
        .mockResolvedValueOnce({
          ok: true,
          json: () => Promise.resolve({ success: true }),
        })
        .mockResolvedValueOnce({
          ok: true,
          text: () => Promise.resolve('<div class="pulse-comments-list">Refreshed</div>'),
        })
      vi.stubGlobal("fetch", mockFetch)

      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement
      const form = formContainer.querySelector("form") as HTMLFormElement
      const textarea = formContainer.querySelector("textarea") as HTMLTextAreaElement

      formContainer.hidden = false
      textarea.value = "Test reply"

      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

      await vi.waitFor(() => {
        expect(mockFetch).toHaveBeenCalled()
      })

      expect(mockFetch.mock.calls[0][0]).toContain("/n/abc123/comments")
      expect(mockFetch.mock.calls[0][1].method).toBe("POST")
      expect(mockFetch.mock.calls[0][1].headers["X-CSRF-Token"]).toBe("test-csrf-token")
    })

    it("shows loading state during submission", async () => {
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

      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement
      const form = formContainer.querySelector("form") as HTMLFormElement
      const textarea = formContainer.querySelector("textarea") as HTMLTextAreaElement
      const submitButton = form.querySelector('[type="submit"]') as HTMLButtonElement
      const cancelButton = form.querySelector('[type="button"]') as HTMLButtonElement

      formContainer.hidden = false
      textarea.value = "Test reply"

      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

      await vi.waitFor(() => {
        expect(submitButton.disabled).toBe(true)
        expect(submitButton.textContent).toBe("Posting...")
        expect(cancelButton.disabled).toBe(true)
        expect(textarea.disabled).toBe(true)
        expect(formContainer.classList.contains("is-loading")).toBe(true)
      })

      resolveSubmit!()
    })

    it("resets form state on error", async () => {
      const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {})
      const mockFetch = vi.fn().mockRejectedValue(new Error("Network error"))
      vi.stubGlobal("fetch", mockFetch)

      const formContainer = document.getElementById("reply-form-abc123") as HTMLElement
      const form = formContainer.querySelector("form") as HTMLFormElement
      const textarea = formContainer.querySelector("textarea") as HTMLTextAreaElement
      const submitButton = form.querySelector('[type="submit"]') as HTMLButtonElement

      formContainer.hidden = false
      textarea.value = "Test reply"

      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

      await vi.waitFor(() => {
        expect(consoleSpy).toHaveBeenCalled()
        expect(submitButton.disabled).toBe(false)
        expect(submitButton.textContent).toBe("Reply")
        expect(textarea.disabled).toBe(false)
      })
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
