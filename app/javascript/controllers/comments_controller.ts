import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { getCsrfToken } from "../utils/csrf"

/**
 * Handles inline comment submission and refreshing for a flat comment thread.
 *
 * Comments render as one chronological list. Replying to a specific comment
 * retargets this single composer at that comment (posting to its `/comments`
 * endpoint makes the new note a reply) and shows a "Replying to…" bar; the
 * reply relationship then surfaces as a "Replying to…" context line on the
 * rendered comment. After a successful submit the composer resets to a
 * top-level comment on the root resource.
 *
 * Subscribes to the resource's CommentsChannel so comments from other users
 * appear live: on a broadcast, the list re-fetches (the same refresh used
 * after a local submit).
 */
export default class CommentsController extends Controller {
  static targets = ["form", "list", "textarea", "submitButton", "replyContext", "replyContextAuthor"]
  static values = {
    refreshUrl: String,
    commentableType: String,
    commentableId: String,
  }

  declare readonly formTarget: HTMLFormElement
  declare readonly listTarget: HTMLElement
  declare readonly textareaTarget: HTMLTextAreaElement
  declare readonly submitButtonTarget: HTMLButtonElement
  declare readonly replyContextTarget: HTMLElement
  declare readonly replyContextAuthorTarget: HTMLElement
  declare readonly refreshUrlValue: string
  declare readonly commentableTypeValue: string
  declare readonly commentableIdValue: string
  declare readonly hasFormTarget: boolean
  declare readonly hasListTarget: boolean
  declare readonly hasTextareaTarget: boolean
  declare readonly hasSubmitButtonTarget: boolean
  declare readonly hasReplyContextTarget: boolean
  declare readonly hasReplyContextAuthorTarget: boolean

  private isSubmitting = false
  // The composer's default action: a top-level comment on the root resource.
  private rootAction = ""
  private subscription: ReturnType<ReturnType<typeof createConsumer>["subscriptions"]["create"]> | null = null

  connect(): void {
    // The composer is absent for logged-out and blocked viewers; the section
    // (and its live-update subscription) still renders for them.
    if (this.hasFormTarget) {
      this.rootAction = this.formTarget.action
    }
    this.subscribeToChannel()
  }

  disconnect(): void {
    this.subscription?.unsubscribe()
    this.subscription = null
  }

  // Live updates: refresh the list whenever the server signals a change.
  private subscribeToChannel(): void {
    if (!this.commentableTypeValue || !this.commentableIdValue) return

    const controller = this
    this.subscription = createConsumer().subscriptions.create(
      {
        channel: "CommentsChannel",
        commentable_type: this.commentableTypeValue,
        commentable_id: this.commentableIdValue,
      },
      {
        received() {
          controller.refreshComments()
        },
      }
    )
  }

  // Retarget the composer at a specific comment and show the "Replying to" bar.
  startReply(event: Event): void {
    const button = event.currentTarget as HTMLElement
    const commentPath = button.dataset.commentPath
    if (!commentPath) return

    this.formTarget.action = `${commentPath}/comments`

    if (this.hasReplyContextAuthorTarget) {
      this.replyContextAuthorTarget.textContent = button.dataset.commentAuthor || "comment"
    }
    if (this.hasReplyContextTarget) {
      this.replyContextTarget.hidden = false
    }
    if (this.hasTextareaTarget) {
      this.textareaTarget.focus()
    }
  }

  // Reset the composer back to a top-level comment on the root resource.
  cancelReply(): void {
    this.formTarget.action = this.rootAction
    if (this.hasReplyContextTarget) {
      this.replyContextTarget.hidden = true
    }
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

        // If the user submitted from the Preview tab, the markdown editor is
        // still showing the (now stale) rendered HTML with the textarea hidden.
        // Reset it to Write mode so the next comment opens ready to type.
        this.resetPreviewToWrite()

        // Drop any reply target so the next comment is top-level again.
        this.cancelReply()

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
      }
    } catch (error) {
      console.error("Error refreshing comments:", error)
    }
  }

  // Return the markdown editor (if any) to Write mode after a submit, so a
  // comment sent from the Preview tab doesn't leave stale rendered HTML behind.
  private resetPreviewToWrite(): void {
    const editor = this.element.querySelector('[data-controller~="markdown-preview"]')
    if (!editor) return
    const controller = this.application.getControllerForElementAndIdentifier(
      editor,
      "markdown-preview"
    ) as { showWrite?: () => void } | null
    controller?.showWrite?.()
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
