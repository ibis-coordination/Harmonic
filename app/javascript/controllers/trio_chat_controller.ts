import { Controller } from "@hotwired/stimulus"

interface Candidate {
  model: string
  response: string
  accepted: number
  preferred: number
}

interface TrioResponse {
  success: boolean
  question?: string
  answer?: string
  error?: string
  winner_index?: number
  candidates?: Candidate[]
}

/**
 * TrioChatController handles the async Q&A interface for the Trio feature.
 * Shows one question and one response at a time.
 *
 * Usage:
 * <div data-controller="trio-chat">
 *   <div data-trio-chat-target="result"></div>
 *   <form data-action="submit->trio-chat#submit">
 *     <textarea data-trio-chat-target="input"></textarea>
 *     <button data-trio-chat-target="submitButton">Ask</button>
 *   </form>
 *   <div data-trio-chat-target="loading" style="display: none;">...</div>
 * </div>
 */
export default class TrioChatController extends Controller<HTMLElement> {
  static targets = ["result", "input", "submitButton", "loading", "loadingText", "form"]

  declare readonly resultTarget: HTMLElement
  declare readonly inputTarget: HTMLTextAreaElement
  declare readonly submitButtonTarget: HTMLButtonElement
  declare readonly loadingTarget: HTMLElement
  declare readonly loadingTextTarget: HTMLElement
  declare readonly formTarget: HTMLFormElement
  declare readonly hasLoadingTarget: boolean
  declare readonly hasLoadingTextTarget: boolean
  declare readonly hasResultTarget: boolean
  declare readonly hasFormTarget: boolean

  private isSubmitting = false
  private dotsAnimationId: number | null = null
  private dotsCount = 0

  private get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  private get formAction(): string {
    // Use form's action URL if available, otherwise default to /trio
    if (this.hasFormTarget) {
      return this.formTarget.action
    }
    // Fallback: find form in element
    const form = this.element.querySelector("form") as HTMLFormElement | null
    return form?.action ?? "/trio"
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
      const response = await fetch(this.formAction, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
          Accept: "application/json",
        },
        body: JSON.stringify({ question }),
      })

      const data: TrioResponse = await response.json()

      if (data.success && data.answer) {
        this.showResult(data)
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

    if (loading) {
      this.startDotsAnimation()
    } else {
      this.stopDotsAnimation()
    }
  }

  private startDotsAnimation(): void {
    if (!this.hasLoadingTextTarget) return

    this.dotsCount = 1
    this.updateDotsText()

    this.dotsAnimationId = window.setInterval(() => {
      this.dotsCount = (this.dotsCount % 3) + 1
      this.updateDotsText()
    }, 400)
  }

  private stopDotsAnimation(): void {
    if (this.dotsAnimationId !== null) {
      clearInterval(this.dotsAnimationId)
      this.dotsAnimationId = null
    }
  }

  private updateDotsText(): void {
    if (!this.hasLoadingTextTarget) return
    const dots = ".".repeat(this.dotsCount)
    this.loadingTextTarget.textContent = `Generating responses and voting${dots}`
  }

  private clearResult(): void {
    if (this.hasResultTarget) {
      this.resultTarget.innerHTML = ""
    }
  }

  private showResult(data: TrioResponse): void {
    if (!this.hasResultTarget) return

    // If we have candidates (experimental voting), show winner first with expandable others
    if (data.candidates && data.candidates.length > 0 && data.winner_index !== undefined && data.winner_index >= 0) {
      const winner = data.candidates[data.winner_index]
      const otherCandidates = data.candidates.filter((_, index) => index !== data.winner_index)

      // Winner card
      const winnerHtml = `
        <div class="trio-chat-candidate trio-chat-winner">
          <div class="trio-chat-candidate-header">
            <strong>${this.escapeHtml(winner.model)}</strong>
            <span class="trio-chat-badge">WINNER</span>
            <span class="trio-chat-votes">
              Accepted: ${winner.accepted} | Preferred: ${winner.preferred}
            </span>
          </div>
          <div class="trio-chat-candidate-response">
            ${this.formatText(winner.response)}
          </div>
        </div>
      `

      // Other candidates (collapsible)
      let otherCandidatesHtml = ""
      if (otherCandidates.length > 0) {
        const othersHtml = otherCandidates
          .map((candidate) => `
            <div class="trio-chat-candidate">
              <div class="trio-chat-candidate-header">
                <strong>${this.escapeHtml(candidate.model)}</strong>
                <span class="trio-chat-votes">
                  Accepted: ${candidate.accepted} | Preferred: ${candidate.preferred}
                </span>
              </div>
              <div class="trio-chat-candidate-response">
                ${this.formatText(candidate.response)}
              </div>
            </div>
          `)
          .join("")

        otherCandidatesHtml = `
          <div class="trio-chat-other-toggle" data-action="click->trio-chat#toggleOtherCandidates">
            <span class="trio-chat-toggle-icon">&#9654;</span>
            Show ${otherCandidates.length} other response${otherCandidates.length > 1 ? "s" : ""}
          </div>
          <div class="trio-chat-other-candidates" style="display: none;">
            ${othersHtml}
          </div>
        `
      }

      this.resultTarget.innerHTML = `
        <div class="trio-chat-candidates">
          ${winnerHtml}
          ${otherCandidatesHtml}
        </div>
      `
    } else {
      // Simple response (non-voting)
      this.resultTarget.innerHTML = `
        <div class="trio-chat-message trio-chat-answer">
          ${this.formatText(data.answer || "")}
        </div>
      `
    }
  }

  toggleOtherCandidates(event: Event): void {
    const toggle = event.currentTarget as HTMLElement
    const container = toggle.nextElementSibling as HTMLElement
    const icon = toggle.querySelector(".trio-chat-toggle-icon") as HTMLElement

    if (container && container.classList.contains("trio-chat-other-candidates")) {
      const isHidden = container.style.display === "none"
      container.style.display = isHidden ? "block" : "none"
      if (icon) {
        icon.innerHTML = isHidden ? "&#9660;" : "&#9654;"
      }
      toggle.innerHTML = toggle.innerHTML.replace(
        isHidden ? "Show" : "Hide",
        isHidden ? "Hide" : "Show"
      )
    }
  }

  private showError(error: string): void {
    if (!this.hasResultTarget) return

    this.resultTarget.innerHTML = `
      <div class="trio-chat-message trio-chat-error">
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
