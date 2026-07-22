import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

/**
 * Per-comment actions within the flat comment list:
 * - Confirms reads (the book icon).
 * - On page load, scrolls to and highlights the comment in `?comment_id=` if present.
 *
 * Replying and composing live in the `comments` controller (the single
 * composer at the bottom of the section).
 */
export default class CommentThreadController extends Controller {
  connect(): void {
    this.highlightCommentFromUrl()
  }

  private highlightCommentFromUrl(): void {
    const params = new URLSearchParams(window.location.search)
    const commentId = params.get("comment_id")
    if (!commentId) return

    const target = document.getElementById(`n-${commentId}`)
    if (!target) return

    // Run after layout so smooth-scroll picks up the element.
    requestAnimationFrame(() => {
      target.scrollIntoView({ behavior: "smooth", block: "center" })
      target.classList.add("pulse-comment-highlighted")
    })

    // Drop the `?comment_id=` param now that we've highlighted. Replying refreshes
    // the comments list, which reconnects this controller; without clearing the
    // param, every reply would re-run the highlight animation on the original
    // comment.
    this.clearCommentIdParam()
  }

  private clearCommentIdParam(): void {
    const url = new URL(window.location.href)
    if (!url.searchParams.has("comment_id")) return

    url.searchParams.delete("comment_id")
    const query = url.searchParams.toString()
    const newUrl = `${url.pathname}${query ? `?${query}` : ""}${url.hash}`
    window.history.replaceState(window.history.state, "", newUrl)
  }

  async confirmRead(event: Event): Promise<void> {
    const button = event.currentTarget as HTMLElement
    const commentPath = button.dataset.commentPath
    if (!commentPath) return

    // Prevent double-clicks
    if (button.classList.contains("is-loading") || button.classList.contains("is-confirmed")) return
    button.classList.add("is-loading")

    try {
      const response = await fetch(`${commentPath}/actions/confirm_read`, {
        method: "POST",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
          Accept: "application/json",
        },
      })

      if (response.ok) {
        const data = await response.json()
        // Update UI immediately with response data
        button.classList.add("is-confirmed")
        const countSpan = button.querySelector(".pulse-confirm-count")
        if (countSpan && data.confirmed_reads !== undefined) {
          countSpan.textContent = String(data.confirmed_reads)
        }
      }
    } catch (error) {
      console.error("Error confirming read:", error)
    } finally {
      button.classList.remove("is-loading")
    }
  }
}
