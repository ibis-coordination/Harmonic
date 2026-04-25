import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { fetchWithCsrf } from "../utils/csrf"

interface ChatMessage {
  type: "message"
  id: string
  sender_id: string
  sender_name: string
  content: string
  content_html: string | null
  timestamp: string
  is_agent: boolean
}

interface StatusEvent {
  type: "status"
  status: "working" | "completed" | "error"
  error?: string
  task_run_id?: string
}

interface ActivityEvent {
  type: "activity"
  text: string
  task_run_id?: string
}

type CableEvent = ChatMessage | StatusEvent | ActivityEvent

interface PollResponse {
  messages: ChatMessage[]
  turn_status: string | null
  turn_error: string | null
  activity: string | null
}

/**
 * AgentChatController handles the chat interface for AI agent conversations.
 *
 * Transport strategy: ActionCable is the primary transport. Polling is a
 * fallback that only activates when the WebSocket connection is lost.
 * The two never run simultaneously, avoiding race conditions from
 * duplicate/stale data.
 */
export default class AgentChatController extends Controller<HTMLElement> {
  static values = {
    url: String,
    agentName: String,
    sessionId: String,
    pollUrl: String,
    turnRunning: Boolean,
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
  declare turnRunningValue: boolean

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
  private indicatorEl: HTMLElement | null = null
  private cableConnected = false

  connect(): void {
    this.scrollToBottom()
    this.subscribeToChannel()

    // If a turn is already running (e.g., page reload), show the indicator
    // and start polling as a bootstrap transport. ActionCable hasn't completed
    // its handshake yet, so we poll until connected() fires and stops it.
    if (this.turnRunningValue) {
      this.waitingForResponse = true
      this.showIndicator("Thinking...")
      this.startPolling()
    }
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

  // --- ActionCable (primary transport) ---

  private subscribeToChannel(): void {
    if (!this.sessionIdValue) return

    const consumer = createConsumer()
    const controller = this

    this.subscription = consumer.subscriptions.create(
      { channel: "ChatSessionChannel", session_id: this.sessionIdValue },
      {
        connected() {
          controller.cableConnected = true
          controller.stopPolling()
        },

        disconnected() {
          controller.cableConnected = false
          // Fall back to polling only while waiting for a response
          if (controller.waitingForResponse) {
            controller.startPolling()
          }
        },

        rejected() {
          controller.cableConnected = false
          if (controller.waitingForResponse) {
            controller.startPolling()
          }
        },

        received(data: CableEvent) {
          switch (data.type) {
            case "message":
              if (data.is_agent) {
                controller.handleAgentMessage(data)
              }
              break
            case "status":
              controller.handleStatusEvent(data)
              break
            case "activity":
              controller.handleActivityEvent(data)
              break
          }
        },
      },
    )
  }

  // --- Event handlers (shared by both transports) ---

  private handleStatusEvent(data: StatusEvent): void {

    switch (data.status) {
      case "working":
        this.showIndicator("Thinking...")
        break
      case "completed":
        this.removeIndicator()
        this.waitingForResponse = false
        break
      case "error":
        this.removeIndicator()
        this.showError(data.error || "Something went wrong. Please try again.")
        this.waitingForResponse = false
        break
    }
  }

  private handleActivityEvent(data: ActivityEvent): void {

    this.showIndicator(data.text)
  }

  private handleAgentMessage(data: ChatMessage): void {

    this.removeIndicator()
    this.appendMessage(
      data.content || "",
      data.sender_name || this.agentNameValue,
      false,
      data.content_html,
    )
    this.lastTimestamp = data.timestamp
    this.waitingForResponse = false
    this.scrollToBottom()
  }

  // --- Message sending ---

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
    this.showIndicator("Thinking...")
    this.scrollToBottom()

    try {
      const response = await fetchWithCsrf(this.urlValue, {
        method: "POST",
        body: JSON.stringify({ message }),
      })

      if (!response.ok) {
        const text = await response.text()
        this.removeIndicator()
        this.markMessageFailed(messageEl, text || response.statusText)
        this.waitingForResponse = false
      } else if (!this.cableConnected) {
        // ActionCable is down — fall back to polling
        this.startPolling()
      }
    } catch {
      this.removeIndicator()
      this.markMessageFailed(messageEl, "Failed to send. Please try again.")
    } finally {
      this.isSubmitting = false
      this.submitButtonTarget.disabled = false
      this.inputTarget.focus()
    }
  }

  // --- Indicator (typing / activity) ---

  private showIndicator(text: string): void {
    if (!this.indicatorEl) {
      this.indicatorEl = document.createElement("div")
      this.indicatorEl.setAttribute("data-chat-indicator", "")
      this.indicatorEl.style.cssText = "display: flex; margin-bottom: 12px; justify-content: flex-start;"

      const bubble = document.createElement("div")
      bubble.style.cssText = "max-width: 75%; padding: 10px 14px; border-radius: 12px; background: var(--color-canvas-subtle);"
      bubble.innerHTML = `
        <div style="font-size: 11px; font-weight: 600; margin-bottom: 4px; color: var(--color-fg-muted);">
          ${this.escapeHtml(this.agentNameValue)}
        </div>
        <div data-indicator-text style="font-size: 13px; color: var(--color-fg-muted); font-style: italic;"></div>
      `
      this.indicatorEl.appendChild(bubble)
      this.messagesTarget.appendChild(this.indicatorEl)
    }

    const textEl = this.indicatorEl.querySelector("[data-indicator-text]")
    if (textEl) {
      textEl.textContent = text
    }
    this.scrollToBottom()
  }

  private removeIndicator(): void {
    if (this.indicatorEl) {
      this.indicatorEl.remove()
      this.indicatorEl = null
    }
  }

  // --- Error display ---

  private showError(message: string): void {
    const wrapper = document.createElement("div")
    wrapper.setAttribute("data-chat-error", "")
    wrapper.style.cssText = "display: flex; margin-bottom: 12px; justify-content: center;"

    const errorBubble = document.createElement("div")
    errorBubble.style.cssText = "padding: 8px 14px; border-radius: 8px; background: var(--color-danger-subtle); color: var(--color-danger-fg); font-size: 13px; max-width: 90%; text-align: center;"
    errorBubble.textContent = message

    wrapper.appendChild(errorBubble)
    this.messagesTarget.appendChild(wrapper)
    this.scrollToBottom()
  }

  // --- Polling (fallback transport, only active when ActionCable is disconnected) ---

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

    // ActionCable reconnected — stop polling, it will take over
    if (this.cableConnected) {
      this.stopPolling()
      return
    }

    try {
      const url = `${this.pollUrlValue}?after=${encodeURIComponent(this.lastTimestamp)}`
      const response = await fetch(url, {
        credentials: "same-origin",
      })

      if (!response.ok) return

      const data = await response.json() as PollResponse

      for (const msg of data.messages) {
        if (msg.is_agent) {
          this.handleAgentMessage(msg)
        }
      }

      if (data.turn_status === "failed" && this.waitingForResponse) {
        this.removeIndicator()
        this.showError(data.turn_error || "Something went wrong. Please try again.")
        this.waitingForResponse = false
        this.stopPolling()
      } else if (data.activity && this.waitingForResponse) {
        this.showIndicator(data.activity)
      }
    } catch {
      // Silent fail — polling is best-effort
    }
  }

  // --- DOM helpers ---

  private appendMessage(content: string, senderName: string, isHuman: boolean, contentHtml?: string | null): HTMLElement {
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

    // Agent messages use server-rendered markdown HTML; human messages use escaped plain text
    const bodyHtml = !isHuman && contentHtml
      ? `<div class="pulse-markdown-content" style="font-size: 14px;">${contentHtml}</div>`
      : `<div style="font-size: 14px; white-space: pre-wrap;">${this.escapeHtml(content)}</div>`

    bubble.innerHTML = `
      <div style="font-size: 11px; font-weight: 600; margin-bottom: 4px; color: var(--color-fg-muted);">
        ${this.escapeHtml(senderName)}
      </div>
      ${bodyHtml}
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
