import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import AgentChatController from "./agent_chat_controller"

// --- ActionCable mock ---

interface MockSubscription {
  connected?: () => void
  disconnected?: () => void
  received?: (data: unknown) => void
  unsubscribe: ReturnType<typeof vi.fn>
}

let mockSubscription: MockSubscription

vi.mock("../utils/csrf", () => ({
  fetchWithCsrf: vi.fn().mockResolvedValue({ ok: true }),
}))

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: (_params: unknown, callbacks: Partial<MockSubscription>) => {
        mockSubscription = {
          ...callbacks,
          unsubscribe: vi.fn(),
        }
        return mockSubscription
      },
    },
  }),
}))

// --- Helpers ---

function setupDOM(options: { turnRunning?: boolean } = {}) {
  document.body.innerHTML = `
    <div data-controller="agent-chat"
         data-agent-chat-url-value="/chat/123/message"
         data-agent-chat-agent-name-value="TestBot"
         data-agent-chat-session-id-value="session-123"
         data-agent-chat-poll-url-value="/chat/123/messages"
         data-agent-chat-turn-running-value="${options.turnRunning ?? false}">
      <div data-agent-chat-target="messages" id="chat-messages"></div>
      <textarea data-agent-chat-target="input"
                data-action="keydown->agent-chat#keydown"></textarea>
      <button data-agent-chat-target="submitButton">Send</button>
    </div>
  `
}

function simulateCableConnected() {
  mockSubscription.connected?.()
}

function simulateCableDisconnected() {
  mockSubscription.disconnected?.()
}

function simulateCableReceived(data: unknown) {
  mockSubscription.received?.(data)
}

function inputField(): HTMLTextAreaElement {
  return document.querySelector("[data-agent-chat-target='input']") as HTMLTextAreaElement
}

function indicatorText(): string | null {
  const el = document.querySelector("[data-indicator-text]")
  return el?.textContent ?? null
}

function hasIndicator(): boolean {
  return document.querySelector("[data-chat-indicator]") !== null
}

function hasError(): boolean {
  return document.querySelector("[data-chat-error]") !== null
}

function errorText(): string | null {
  const el = document.querySelector("[data-chat-error]")
  return el?.textContent ?? null
}

function messageTexts(): string[] {
  return Array.from(document.querySelectorAll("[data-chat-message]")).map(
    (el) => {
      // The message content is in the second div inside the bubble
      // Structure: wrapper > bubble > [sender, content, time]
      const bubble = el.firstElementChild
      const divs = bubble?.querySelectorAll(":scope > div") ?? []
      return (divs[1] as HTMLElement)?.textContent?.trim() ?? ""
    },
  )
}

describe("AgentChatController", () => {
  let application: Application

  beforeEach(() => {
    vi.useFakeTimers()
    vi.stubGlobal("fetch", vi.fn())
    setupDOM()
    application = Application.start()
    application.register("agent-chat", AgentChatController)
  })

  afterEach(() => {
    application.stop()
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  // --- ActionCable as primary transport ---

  describe("ActionCable transport", () => {
    it("receives agent messages via ActionCable", () => {
      simulateCableConnected()
      simulateCableReceived({
        type: "message",
        content: "Hello human!",
        sender_name: "TestBot",
        is_agent: true,
        timestamp: new Date().toISOString(),
        id: "msg-1",
        sender_id: "agent-1",
      })

      expect(messageTexts()).toContain("Hello human!")
    })

    it("shows typing indicator on working status", () => {
      simulateCableConnected()
      simulateCableReceived({ type: "status", status: "working" })

      expect(hasIndicator()).toBe(true)
      expect(indicatorText()).toBe("Thinking...")
    })

    it("shows activity text from activity events", () => {
      simulateCableConnected()
      simulateCableReceived({ type: "activity", text: "Navigating to /collectives/team" })

      expect(indicatorText()).toBe("Navigating to /collectives/team")
    })

    it("removes indicator on completed status", () => {
      simulateCableConnected()
      simulateCableReceived({ type: "status", status: "working" })
      expect(hasIndicator()).toBe(true)

      simulateCableReceived({ type: "status", status: "completed" })
      expect(hasIndicator()).toBe(false)
    })

    it("shows error on error status", () => {
      simulateCableConnected()
      simulateCableReceived({ type: "status", status: "error", error: "LLM crashed" })

      expect(hasIndicator()).toBe(false)
      expect(hasError()).toBe(true)
      expect(errorText()).toBe("LLM crashed")
    })

    it("removes indicator when agent message arrives", () => {
      simulateCableConnected()
      simulateCableReceived({ type: "status", status: "working" })
      expect(hasIndicator()).toBe(true)

      simulateCableReceived({
        type: "message",
        content: "Done!",
        sender_name: "TestBot",
        is_agent: true,
        timestamp: new Date().toISOString(),
        id: "msg-2",
        sender_id: "agent-1",
      })

      expect(hasIndicator()).toBe(false)
      expect(messageTexts()).toContain("Done!")
    })

    it("ignores non-agent messages from ActionCable", () => {
      simulateCableConnected()
      simulateCableReceived({
        type: "message",
        content: "Human echo",
        sender_name: "User",
        is_agent: false,
        timestamp: new Date().toISOString(),
        id: "msg-3",
        sender_id: "user-1",
      })

      expect(messageTexts()).not.toContain("Human echo")
    })
  })

  // --- Polling fallback ---

  describe("polling fallback", () => {
    it("does not poll when ActionCable is connected", async () => {
      const mockFetch = vi.fn()
      vi.stubGlobal("fetch", mockFetch)

      simulateCableConnected()

      // Simulate sending a message (with cable connected, should not start polling)
      const fetchWithCsrf = vi.fn().mockResolvedValue({ ok: true })
      vi.stubGlobal("fetch", fetchWithCsrf)

      // Advance timers — no poll should fire
      await vi.advanceTimersByTimeAsync(10000)

      // Only the message send fetch, not any poll fetches
      // (fetchWithCsrf is used for sends, plain fetch for polls)
      const pollCalls = fetchWithCsrf.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      )
      expect(pollCalls).toHaveLength(0)
    })

    it("starts polling when ActionCable disconnects while waiting", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ messages: [], turn_status: "running", turn_error: null, activity: null }),
      })
      vi.stubGlobal("fetch", mockFetch)

      simulateCableConnected()

      // Set waiting state (simulates a message was sent)
      // Access private field via type assertion for testing
      const controller = application.getControllerForElementAndIdentifier(
        document.querySelector("[data-controller='agent-chat']")!,
        "agent-chat",
      ) as unknown as { waitingForResponse: boolean }
      controller.waitingForResponse = true

      // Cable drops
      simulateCableDisconnected()

      // Advance timer — should trigger polling
      await vi.advanceTimersByTimeAsync(3500)

      const pollCalls = mockFetch.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      )
      expect(pollCalls.length).toBeGreaterThan(0)
    })

    it("stops polling when ActionCable reconnects", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ messages: [], turn_status: "running", turn_error: null, activity: null }),
      })
      vi.stubGlobal("fetch", mockFetch)

      // Start disconnected with a running turn
      const controller = application.getControllerForElementAndIdentifier(
        document.querySelector("[data-controller='agent-chat']")!,
        "agent-chat",
      ) as unknown as { waitingForResponse: boolean }
      controller.waitingForResponse = true

      simulateCableDisconnected()
      await vi.advanceTimersByTimeAsync(3500)

      const pollCountBefore = mockFetch.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      ).length
      expect(pollCountBefore).toBeGreaterThan(0)

      // Cable reconnects — should stop polling
      simulateCableConnected()
      mockFetch.mockClear()

      await vi.advanceTimersByTimeAsync(10000)

      const pollCountAfter = mockFetch.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      ).length
      expect(pollCountAfter).toBe(0)
    })

    it("delivers agent message via polling when cable is down", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({
          messages: [{
            type: "message",
            id: "msg-poll-1",
            sender_id: "agent-1",
            sender_name: "TestBot",
            content: "Polled response!",
            timestamp: new Date().toISOString(),
            is_agent: true,
          }],
          turn_status: null,
          turn_error: null,
          activity: null,
        }),
      })
      vi.stubGlobal("fetch", mockFetch)

      const controller = application.getControllerForElementAndIdentifier(
        document.querySelector("[data-controller='agent-chat']")!,
        "agent-chat",
      ) as unknown as { waitingForResponse: boolean }
      controller.waitingForResponse = true

      simulateCableDisconnected()

      await vi.advanceTimersByTimeAsync(3500)

      await vi.waitFor(() => {
        expect(messageTexts()).toContain("Polled response!")
      })
    })

    it("shows error from polling when turn fails", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({
          messages: [],
          turn_status: "failed",
          turn_error: "LLM quota exceeded",
          activity: null,
        }),
      })
      vi.stubGlobal("fetch", mockFetch)

      const controller = application.getControllerForElementAndIdentifier(
        document.querySelector("[data-controller='agent-chat']")!,
        "agent-chat",
      ) as unknown as { waitingForResponse: boolean }
      controller.waitingForResponse = true

      simulateCableDisconnected()

      await vi.advanceTimersByTimeAsync(3500)

      await vi.waitFor(() => {
        expect(hasError()).toBe(true)
        expect(errorText()).toBe("LLM quota exceeded")
      })
    })

    it("polls on page reload with running turn until cable connects", async () => {
      application.stop()

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ messages: [], turn_status: "running", turn_error: null, activity: null }),
      })
      vi.stubGlobal("fetch", mockFetch)

      setupDOM({ turnRunning: true })
      application = Application.start()
      application.register("agent-chat", AgentChatController)

      // Polling should start immediately (cable not connected yet)
      await vi.advanceTimersByTimeAsync(3500)

      const pollCalls = mockFetch.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      )
      expect(pollCalls.length).toBeGreaterThan(0)

      // Cable connects — polling should stop
      simulateCableConnected()
      mockFetch.mockClear()

      await vi.advanceTimersByTimeAsync(10000)
      const pollsAfterConnect = mockFetch.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      )
      expect(pollsAfterConnect).toHaveLength(0)
    })
  })

  // --- Message sending ---

  describe("sending messages", () => {
    it("appends user message optimistically and shows indicator", async () => {
      simulateCableConnected()

      inputField().value = "Hello agent"

      const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true })
      inputField().dispatchEvent(event)

      await vi.waitFor(() => {
        expect(messageTexts()).toContain("Hello agent")
      })
      expect(hasIndicator()).toBe(true)
    })

    it("does not poll after send when cable is connected", async () => {
      const mockFetch = vi.fn()
      vi.stubGlobal("fetch", mockFetch)

      simulateCableConnected()
      inputField().value = "Test"

      const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true })
      inputField().dispatchEvent(event)

      await vi.waitFor(() => {
        expect(messageTexts()).toContain("Test")
      })

      // Advance past several poll intervals — no polls should fire
      await vi.advanceTimersByTimeAsync(15000)

      const pollCalls = mockFetch.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      )
      expect(pollCalls).toHaveLength(0)
    })

    it("starts polling after send when cable is disconnected", async () => {
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ messages: [], turn_status: "running", turn_error: null, activity: null }),
      })
      vi.stubGlobal("fetch", mockFetch)

      // Cable never connects — cableConnected stays false
      inputField().value = "Test"

      const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true })
      inputField().dispatchEvent(event)

      await vi.waitFor(() => {
        expect(messageTexts()).toContain("Test")
      })

      await vi.advanceTimersByTimeAsync(3500)

      const pollCalls = mockFetch.mock.calls.filter(
        (call: unknown[]) => typeof call[0] === "string" && (call[0] as string).includes("/messages?after="),
      )
      expect(pollCalls.length).toBeGreaterThan(0)
    })

    it("does not send empty messages", async () => {
      const { fetchWithCsrf } = await import("../utils/csrf")
      vi.mocked(fetchWithCsrf).mockClear()

      simulateCableConnected()
      inputField().value = "   "

      const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true })
      inputField().dispatchEvent(event)

      await vi.advanceTimersByTimeAsync(0)

      expect(messageTexts()).toHaveLength(0)
      expect(fetchWithCsrf).not.toHaveBeenCalled()
    })
  })

  // --- Indicator behavior ---

  describe("indicator", () => {
    it("updates indicator text on successive activity events", () => {
      simulateCableConnected()
      simulateCableReceived({ type: "status", status: "working" })
      expect(indicatorText()).toBe("Thinking...")

      simulateCableReceived({ type: "activity", text: "Navigating to /notes" })
      expect(indicatorText()).toBe("Navigating to /notes")

      simulateCableReceived({ type: "activity", text: "Executing create_note" })
      expect(indicatorText()).toBe("Executing create_note")
    })

    it("shows indicator on page load when turn is running", async () => {
      application.stop()
      setupDOM({ turnRunning: true })
      application = Application.start()
      application.register("agent-chat", AgentChatController)

      // Wait for Stimulus to connect the controller
      await vi.advanceTimersByTimeAsync(0)

      expect(hasIndicator()).toBe(true)
      expect(indicatorText()).toBe("Thinking...")
    })
  })
})
