import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { fetchWithCsrf } from "../utils/csrf"

interface ChatMessage {
  type: "message"
  id: string
  sender_id: string
  sender_name: string
  content: string
  timestamp: string
  is_agent: boolean
}

/**
 * AgentChatController handles the chat interface for AI agent conversations.
 * Sends messages via AJAX, appends them to the DOM optimistically,
 * subscribes to ActionCable for agent responses (with polling fallback),
 * and auto-scrolls.
 */
export default class AgentChatController extends Controller<HTMLElement> {
  static values = {
    url: String,
    agentName: String,
    sessionId: String,
    pollUrl: String,
  }

  static targets = [
    "messages",
    "input",
    "submitButton",
    "emptyState",
  ]

  declare urlValue: string
  declare agentNameValue: string
  declare sessionIdValue: string
  declare pollUrlValue: string

  declare readonly messagesTarget: HTMLElement
  declare readonly inputTarget: HTMLTextAreaElement
  declare readonly submitButtonTarget: HTMLButtonElement
  declare readonly hasEmptyStateTarget: boolean
  declare readonly emptyStateTarget: HTMLElement

  private isSubmitting = false
  private subscription: ReturnType<ReturnType<typeof createConsumer>["subscriptions"]["create"]> | null = null
  private pollTimer: number | null = null
  private lastTimestamp: string = new Date().toISOString()
  private waitingForResponse = false

  connect(): void {
    this.scrollToBottom()
    this.subscribeToChannel()
  }

  disconnect(): void {
    this.subscription?.unsubscribe()
    this.subscription = null
    this.stopPolling()
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

  private subscribeToChannel(): void {
    if (!this.sessionIdValue) return

    const consumer = createConsumer()
    const controller = this

    this.subscription = consumer.subscriptions.create(
      { channel: "ChatSessionChannel", session_id: this.sessionIdValue },
      {
        received(data: ChatMessage) {
          if (data.type === "message" && data.is_agent) {
            controller.stopPolling()
            controller.handleAgentMessage(data)
          }
        },
      },
    )
  }

  private handleAgentMessage(data: ChatMessage): void {
    this.appendMessage(
      data.content || "",
      data.sender_name || this.agentNameValue,
      false,
    )
    this.lastTimestamp = data.timestamp
    this.waitingForResponse = false
    this.stopPolling()
    this.scrollToBottom()
  }

  private async sendMessage(): Promise<void> {
    if (this.isSubmitting) return

    const message = this.inputTarget.value.trim()
    if (!message) return

    this.isSubmitting = true
    this.inputTarget.value = ""
    this.submitButtonTarget.disabled = true

    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.remove()
    }

    const messageEl = this.appendMessage(message, "You", true)
    this.lastTimestamp = new Date().toISOString()
    this.waitingForResponse = true
    this.scrollToBottom()

    try {
      const response = await fetchWithCsrf(this.urlValue, {
        method: "POST",
        body: JSON.stringify({ message }),
      })

      if (!response.ok) {
        const text = await response.text()
        this.markMessageFailed(messageEl, text || response.statusText)
        this.waitingForResponse = false
      } else {
        this.startPolling()
      }
    } catch {
      this.markMessageFailed(messageEl, "Failed to send. Please try again.")
    } finally {
      this.isSubmitting = false
      this.submitButtonTarget.disabled = false
      this.inputTarget.focus()
    }
  }

  // Polling fallback: check for new messages via the poll endpoint
  // if ActionCable doesn't deliver them.
  private startPolling(): void {
    if (this.pollTimer !== null) return

    this.pollTimer = window.setInterval(() => {
      this.pollForMessages()
    }, 3000)
  }

  private stopPolling(): void {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  private async pollForMessages(): Promise<void> {
    if (!this.pollUrlValue || !this.waitingForResponse) {
      this.stopPolling()
      return
    }

    try {
      const url = `${this.pollUrlValue}?after=${encodeURIComponent(this.lastTimestamp)}`
      const response = await fetch(url, {
        credentials: "same-origin",
      })

      if (!response.ok) return

      const data = await response.json() as { messages: ChatMessage[] }
      for (const msg of data.messages) {
        if (msg.is_agent) {
          this.handleAgentMessage(msg)
        }
      }
    } catch {
      // Silent fail — polling is best-effort
    }
  }

  private appendMessage(content: string, senderName: string, isHuman: boolean): HTMLElement {
    const time = new Date().toLocaleTimeString("en-US", {
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    })

    const wrapper = document.createElement("div")
    wrapper.setAttribute("data-chat-message", "")
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
