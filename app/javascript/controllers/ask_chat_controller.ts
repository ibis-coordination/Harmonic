import { Controller } from "@hotwired/stimulus"

interface AskResponse {
  success: boolean
  question?: string
  answer?: string
  error?: string
}

/**
 * AskChatController handles the async Q&A interface for the Ask Harmonic feature.
 * Shows one question and one response at a time.
 *
 * Usage:
 * <div data-controller="ask-chat">
 *   <div data-ask-chat-target="result"></div>
 *   <form data-action="submit->ask-chat#submit">
 *     <textarea data-ask-chat-target="input"></textarea>
 *     <button data-ask-chat-target="submitButton">Ask</button>
 *   </form>
 *   <div data-ask-chat-target="loading" style="display: none;">...</div>
 * </div>
 */
export default class AskChatController extends Controller<HTMLElement> {
  static targets = ["result", "input", "submitButton", "loading"]

  declare readonly resultTarget: HTMLElement
  declare readonly inputTarget: HTMLTextAreaElement
  declare readonly submitButtonTarget: HTMLButtonElement
  declare readonly loadingTarget: HTMLElement
  declare readonly hasLoadingTarget: boolean
  declare readonly hasResultTarget: boolean

  private isSubmitting = false

  private get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  keydown(event: KeyboardEvent): void {
    // Submit on Enter (without Shift for multiline)
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.submitQuestion()
    }
  }

  async submit(event: Event): Promise<void> {
    event.preventDefault()
    this.submitQuestion()
  }

  private async submitQuestion(): Promise<void> {
    if (this.isSubmitting) return

    const question = this.inputTarget.value.trim()
    if (!question) return

    this.isSubmitting = true
    this.setLoadingState(true)
    this.clearResult()

    try {
      const response = await fetch("/ask", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
          Accept: "application/json",
        },
        body: JSON.stringify({ question }),
      })

      const data: AskResponse = await response.json()

      if (data.success && data.answer) {
        this.showResult(data.answer)
      } else {
        this.showError(data.error || "An error occurred. Please try again.")
      }
    } catch (error) {
      console.error("Error submitting question:", error)
      this.showError("Failed to connect. Please try again.")
    } finally {
      this.isSubmitting = false
      this.setLoadingState(false)
      this.inputTarget.focus()
    }
  }

  private setLoadingState(loading: boolean): void {
    if (this.hasLoadingTarget) {
      this.loadingTarget.style.display = loading ? "flex" : "none"
    }
    this.submitButtonTarget.disabled = loading
    this.inputTarget.disabled = loading
  }

  private clearResult(): void {
    if (this.hasResultTarget) {
      this.resultTarget.innerHTML = ""
    }
  }

  private showResult(answer: string): void {
    if (!this.hasResultTarget) return

    this.resultTarget.innerHTML = `
      <div class="ask-chat-message ask-chat-answer">
        ${this.formatText(answer)}
      </div>
    `
  }

  private showError(error: string): void {
    if (!this.hasResultTarget) return

    this.resultTarget.innerHTML = `
      <div class="ask-chat-message ask-chat-error">
        <em>${this.escapeHtml(error)}</em>
      </div>
    `
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  private formatText(text: string): string {
    // Simple formatting: escape HTML then convert double newlines to paragraphs, single to <br>
    const escaped = this.escapeHtml(text)
    return escaped
      .split(/\n\n+/)
      .map((para) => `<p>${para.replace(/\n/g, "<br>")}</p>`)
      .join("")
  }
}
