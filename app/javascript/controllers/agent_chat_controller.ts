import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

/**
 * AgentChatController handles the chat interface for AI agent conversations.
 * Sends messages via AJAX, appends them to the DOM optimistically, and
 * auto-scrolls to the latest message.
 *
 * Usage:
 * <div data-controller="agent-chat"
 *      data-agent-chat-url-value="/ai-agents/handle/chat/message"
 *      data-agent-chat-agent-name-value="AgentName">
 *   <div data-agent-chat-target="messages">...</div>
 *   <textarea data-agent-chat-target="input"></textarea>
 *   <button data-agent-chat-target="submitButton">Send</button>
 * </div>
 */
export default class AgentChatController extends Controller<HTMLElement> {
  static values = {
    url: String,
    agentName: String,
  }

  static targets = [
    "messages",
    "input",
    "submitButton",
    "emptyState",
  ]

  declare urlValue: string
  declare agentNameValue: string

  declare readonly messagesTarget: HTMLElement
  declare readonly inputTarget: HTMLTextAreaElement
  declare readonly submitButtonTarget: HTMLButtonElement
  declare readonly hasEmptyStateTarget: boolean
  declare readonly emptyStateTarget: HTMLElement

  private isSubmitting = false

  connect(): void {
    this.scrollToBottom()
  }

  keydown(event: KeyboardEvent): void {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.sendMessage()
    }
  }

  async submit(event: Event): Promise<void> {
    event.preventDefault()
    this.sendMessage()
  }

  private async sendMessage(): Promise<void> {
    if (this.isSubmitting) return

    const message = this.inputTarget.value.trim()
    if (!message) return

    this.isSubmitting = true
    this.inputTarget.value = ""
    this.submitButtonTarget.disabled = true

    // Remove empty state
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.remove()
    }

    // Optimistically append the message to the UI
    const messageEl = this.appendMessage(message, "You", true)
    this.scrollToBottom()

    try {
      const response = await fetchWithCsrf(this.urlValue, {
        method: "POST",
        body: JSON.stringify({ message }),
      })

      if (!response.ok) {
        const text = await response.text()
        this.markMessageFailed(messageEl, text || response.statusText)
      }
    } catch {
      this.markMessageFailed(messageEl, "Failed to send. Please try again.")
    } finally {
      this.isSubmitting = false
      this.submitButtonTarget.disabled = false
      this.inputTarget.focus()
    }
  }

  private appendMessage(content: string, senderName: string, isHuman: boolean): HTMLElement {
    const time = new Date().toLocaleTimeString("en-US", {
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    })

    const wrapper = document.createElement("div")
    wrapper.style.cssText = `display: flex; margin-bottom: 12px; justify-content: ${isHuman ? "flex-end" : "flex-start"};`

    const bubble = document.createElement("div")
    bubble.style.cssText = `max-width: 75%; padding: 10px 14px; border-radius: 12px; background: ${isHuman ? "var(--color-accent-subtle)" : "var(--color-canvas-subtle)"};`

    bubble.innerHTML = `
      <div style="font-size: 11px; font-weight: 600; margin-bottom: 4px; color: var(--color-fg-muted);">
        ${this.escapeHtml(senderName)}
      </div>
      <div style="font-size: 14px; white-space: pre-wrap;">${this.escapeHtml(content)}</div>
      <div style="font-size: 11px; color: var(--color-fg-muted); margin-top: 4px;">
        ${time}
      </div>
    `

    wrapper.appendChild(bubble)
    this.messagesTarget.appendChild(wrapper)

    return wrapper
  }

  private markMessageFailed(messageEl: HTMLElement, error: string): void {
    const errorEl = document.createElement("div")
    errorEl.style.cssText = "font-size: 11px; color: var(--color-danger-fg); margin-top: 4px;"
    errorEl.textContent = error

    const bubble = messageEl.firstElementChild
    if (bubble) {
      bubble.appendChild(errorEl)
      ;(bubble as HTMLElement).style.opacity = "0.6"
    }

    this.scrollToBottom()
  }

  private scrollToBottom(): void {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
