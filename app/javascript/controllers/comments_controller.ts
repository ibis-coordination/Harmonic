import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

/**
 * Handles inline comment submission and refreshing.
 * Intercepts form submission to prevent page redirect and refreshes
 * the comments section after a successful submission.
 */
export default class CommentsController extends Controller {
  static targets = ["form", "list", "textarea", "submitButton"]
  static values = {
    refreshUrl: String,
  }

  declare readonly formTarget: HTMLFormElement
  declare readonly listTarget: HTMLElement
  declare readonly textareaTarget: HTMLTextAreaElement
  declare readonly submitButtonTarget: HTMLButtonElement
  declare readonly refreshUrlValue: string
  declare readonly hasListTarget: boolean
  declare readonly hasTextareaTarget: boolean
  declare readonly hasSubmitButtonTarget: boolean

  private isSubmitting = false

  async submit(event: Event): Promise<void> {
    event.preventDefault()

    if (this.isSubmitting) return

    const form = this.formTarget
    const formData = new FormData(form)

    // Check if the comment text is empty
    const text = formData.get("text") as string
    if (!text || text.trim() === "") {
      return
    }

    this.isSubmitting = true
    this.showLoadingState()

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
        // Clear the form
        if (this.hasTextareaTarget) {
          this.textareaTarget.value = ""
        }

        // Refresh the comments list
        await this.refreshComments()
      } else {
        console.error("Error submitting comment:", response.statusText)
      }
    } catch (error) {
      console.error("Error submitting comment:", error)
    } finally {
      this.isSubmitting = false
      this.hideLoadingState()
    }
  }

  async refreshComments(): Promise<void> {
    if (!this.refreshUrlValue) return

    // Find the list element directly (don't rely on cached target)
    const listElement = this.element.querySelector(".pulse-comments-list")
    if (!listElement) return

    // Save expanded thread state before refresh
    const expandedThreadIds = this.getExpandedThreadIds()

    try {
      const response = await fetch(this.refreshUrlValue, {
        headers: {
          Accept: "text/html",
        },
      })

      if (response.ok) {
        const html = await response.text()

        // Parse the new HTML and replace the old element
        const template = document.createElement("template")
        template.innerHTML = html.trim()
        const newElement = template.content.firstElementChild as HTMLElement

        if (newElement) {
          listElement.replaceWith(newElement)
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
    // Find all toggle buttons that are NOT collapsed (i.e., thread is expanded)
    this.element.querySelectorAll(".pulse-replies-toggle:not(.is-collapsed)").forEach((btn) => {
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
        // Expand the thread
        repliesContainer.hidden = false
        toggleButton.classList.remove("is-collapsed")
        toggleButton.setAttribute("aria-expanded", "true")

        // Update button text
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

  private showLoadingState(): void {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
      this.submitButtonTarget.textContent = "Adding..."
    }
  }

  private hideLoadingState(): void {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = false
      this.submitButtonTarget.textContent = "Add Comment"
    }
  }
}
