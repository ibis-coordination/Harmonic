import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

/**
 * Handles inline reply forms within comment threads.
 * - Shows/hides reply forms
 * - Updates the reply target when replying to nested comments
 * - Submits replies via AJAX and refreshes the thread
 */
export default class CommentThreadController extends Controller {

  private async refreshCommentsList(): Promise<void> {
    // Find the parent comments section and get the refresh URL
    const commentsSection = this.element.closest(".pulse-comments-section")
    if (!commentsSection) return

    const refreshUrl = (commentsSection as HTMLElement).dataset.commentsRefreshUrlValue
    if (!refreshUrl) return

    // Save expanded thread state before refresh
    const expandedThreadIds = this.getExpandedThreadIds()

    try {
      const response = await fetch(refreshUrl, {
        headers: {
          Accept: "text/html",
        },
      })

      if (response.ok) {
        const html = await response.text()

        // Find and replace the list element
        const listElement = commentsSection.querySelector(".pulse-comments-list")
        if (listElement) {
          const template = document.createElement("template")
          template.innerHTML = html.trim()
          const newElement = template.content.firstElementChild as HTMLElement
          if (newElement) {
            listElement.replaceWith(newElement)
          }
        }

        // Restore expanded thread state after refresh
        this.restoreExpandedThreads(expandedThreadIds)
      }
    } catch (error) {
      console.error("Error refreshing comments:", error)
    }
  }

  private getExpandedThreadIds(): Set<string> {
    const expandedIds = new Set<string>()
    const commentsSection = this.element.closest(".pulse-comments-section")
    if (!commentsSection) return expandedIds

    commentsSection.querySelectorAll(".pulse-replies-toggle:not(.is-collapsed)").forEach((btn) => {
      const threadId = (btn as HTMLElement).dataset.threadId
      if (threadId) {
        expandedIds.add(threadId)
      }
    })
    return expandedIds
  }

  private restoreExpandedThreads(expandedIds: Set<string>): void {
    expandedIds.forEach((threadId) => {
      const repliesContainer = document.getElementById(`replies-${threadId}`)
      const toggleButton = document.querySelector(
        `.pulse-replies-toggle[data-thread-id="${threadId}"]`
      ) as HTMLElement

      if (repliesContainer && toggleButton) {
        repliesContainer.hidden = false
        toggleButton.classList.remove("is-collapsed")
        toggleButton.setAttribute("aria-expanded", "true")

        const textSpan = toggleButton.querySelector(".pulse-replies-toggle-text") as HTMLElement
        const replyCount = toggleButton.dataset.replyCount
        if (textSpan && replyCount) {
          const count = parseInt(replyCount, 10)
          const replyWord = count === 1 ? "reply" : "replies"
          textSpan.textContent = `Hide ${replyWord}`
        }
      }
    })
  }

  showReplyForm(event: Event): void {
    const button = event.currentTarget as HTMLElement
    const commentId = button.dataset.commentId
    const rootCommentId = button.dataset.rootCommentId

    // Hide any other open reply forms
    this.element.querySelectorAll(".pulse-reply-form-container").forEach((el) => {
      ;(el as HTMLElement).hidden = true
    })

    // Show the reply form for this thread
    const formContainer = document.getElementById(`reply-form-${rootCommentId}`)
    if (formContainer) {
      formContainer.hidden = false

      // Update the form action to reply to the correct comment
      const form = formContainer.querySelector("form") as HTMLFormElement
      if (form && commentId) {
        // Update form action to point to the comment being replied to
        // Extract the base path and update with the correct comment ID
        const currentAction = form.action
        const match = currentAction.match(/(.*)\/n\/[^/]+\/comments/)
        if (match) {
          form.action = `${match[1]}/n/${commentId}/comments`
        }

        // Update hidden field
        const hiddenInput = formContainer.querySelector(
          `#reply-to-${rootCommentId}`
        ) as HTMLInputElement
        if (hiddenInput) {
          hiddenInput.value = commentId
        }
      }

      formContainer.querySelector("textarea")?.focus()
    }
  }

  hideReplyForm(event: Event): void {
    const formContainer = (event.currentTarget as HTMLElement).closest(
      ".pulse-reply-form-container"
    ) as HTMLElement
    if (formContainer) {
      formContainer.hidden = true
      // Clear the textarea
      const textarea = formContainer.querySelector("textarea") as HTMLTextAreaElement
      if (textarea) textarea.value = ""
    }
  }

  toggleReplies(event: Event): void {
    const button = event.currentTarget as HTMLElement
    const threadId = button.dataset.threadId
    const replyCount = button.dataset.replyCount
    const repliesContainer = document.getElementById(`replies-${threadId}`)
    const textSpan = button.querySelector(".pulse-replies-toggle-text") as HTMLElement

    if (!repliesContainer) return

    const isCollapsed = repliesContainer.hidden
    repliesContainer.hidden = !isCollapsed
    button.classList.toggle("is-collapsed", !isCollapsed)
    button.setAttribute("aria-expanded", isCollapsed ? "true" : "false")

    if (textSpan && replyCount) {
      const count = parseInt(replyCount, 10)
      const replyWord = count === 1 ? "reply" : "replies"
      textSpan.textContent = isCollapsed ? `Hide ${replyWord}` : `${count} ${replyWord}`
    }
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

  async submitReply(event: Event): Promise<void> {
    event.preventDefault()
    const form = event.currentTarget as HTMLFormElement
    const formData = new FormData(form)
    const formContainer = form.closest(
      ".pulse-reply-form-container"
    ) as HTMLElement

    // Check if the reply text is empty
    const text = formData.get("text") as string
    if (!text || text.trim() === "") {
      return
    }

    const submitButton = form.querySelector(
      'button[type="submit"], input[type="submit"]'
    ) as HTMLButtonElement
    const cancelButton = form.querySelector(
      'button[type="button"]'
    ) as HTMLButtonElement
    const textarea = form.querySelector("textarea") as HTMLTextAreaElement

    // Show loading state - keep form visible but disabled
    if (formContainer) {
      formContainer.classList.add("is-loading")
    }
    if (submitButton) {
      submitButton.disabled = true
      submitButton.textContent = "Posting..."
    }
    if (cancelButton) {
      cancelButton.disabled = true
    }
    if (textarea) {
      textarea.disabled = true
    }

    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
          Accept: "application/json",
        },
        body: formData,
      })

      if (response.ok) {
        await this.refreshCommentsList()
      } else {
        // On error, restore form to usable state
        this.resetFormState(formContainer, submitButton, cancelButton, textarea)
      }
    } catch (error) {
      console.error("Error submitting reply:", error)
      // On error, restore form to usable state
      this.resetFormState(formContainer, submitButton, cancelButton, textarea)
    }
  }

  private resetFormState(
    formContainer: HTMLElement | null,
    submitButton: HTMLButtonElement | null,
    cancelButton: HTMLButtonElement | null,
    textarea: HTMLTextAreaElement | null
  ): void {
    if (formContainer) {
      formContainer.classList.remove("is-loading")
    }
    if (submitButton) {
      submitButton.disabled = false
      submitButton.textContent = "Reply"
    }
    if (cancelButton) {
      cancelButton.disabled = false
    }
    if (textarea) {
      textarea.disabled = false
    }
  }
}
