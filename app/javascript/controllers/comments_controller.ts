import { Controller } from "@hotwired/stimulus"

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

  get csrfToken(): string {
    const meta = document.querySelector(
      "meta[name='csrf-token']"
    ) as HTMLMetaElement | null
    return meta?.content ?? ""
  }

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
          "X-CSRF-Token": this.csrfToken,
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
    if (!this.refreshUrlValue || !this.hasListTarget) return

    try {
      const response = await fetch(this.refreshUrlValue, {
        headers: {
          Accept: "text/html",
        },
      })

      if (response.ok) {
        const html = await response.text()
        this.listTarget.outerHTML = html
      }
    } catch (error) {
      console.error("Error refreshing comments:", error)
    }
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

  // Handle reply added event from nested comment-thread controller
  replyAdded(event: CustomEvent): void {
    this.refreshComments()
  }
}
