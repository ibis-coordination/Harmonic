import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import MentionAutocompleteController from "./mention_autocomplete_controller"

describe("MentionAutocompleteController", () => {
  let application: Application

  beforeEach(() => {
    vi.useFakeTimers()

    // Set up DOM with studio path value
    document.body.innerHTML = `
      <div data-controller="mention-autocomplete"
           data-mention-autocomplete-studio-path-value="/studios/test-studio"
           class="mention-autocomplete-container">
        <textarea data-mention-autocomplete-target="input"></textarea>
        <div data-mention-autocomplete-target="dropdown" class="mention-dropdown" style="display: none;"></div>
      </div>
    `

    // Start Stimulus application
    application = Application.start()
    application.register("mention-autocomplete", MentionAutocompleteController)
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("initializes with input and dropdown targets", () => {
    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement
    expect(inputElement).toBeDefined()
    expect(dropdownElement).toBeDefined()
    expect(dropdownElement.style.display).toBe("none")
  })

  it("shows dropdown when @ is typed followed by text", async () => {
    const mockUsers = [
      { id: "1", handle: "alice", display_name: "Alice Smith", avatar_url: null },
      { id: "2", handle: "alex", display_name: "Alex Jones", avatar_url: null },
    ]

    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(mockUsers),
    })
    vi.stubGlobal("fetch", mockFetch)

    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement

    // Type @al
    inputElement.value = "@al"
    inputElement.selectionStart = 3
    inputElement.dispatchEvent(new Event("input"))

    // Wait for debounce
    await vi.advanceTimersByTimeAsync(200)

    await vi.waitFor(() => {
      expect(mockFetch).toHaveBeenCalledWith("/studios/test-studio/autocomplete/users?q=al", expect.any(Object))
      expect(dropdownElement.style.display).toBe("block")
      expect(dropdownElement.innerHTML).toContain("alice")
      expect(dropdownElement.innerHTML).toContain("alex")
    })
  })

  it("hides dropdown when no @ is present", () => {
    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement

    // Type without @
    inputElement.value = "hello world"
    inputElement.selectionStart = 11
    inputElement.dispatchEvent(new Event("input"))

    expect(dropdownElement.style.display).toBe("none")
  })

  it("inserts selected user handle into input", async () => {
    const mockUsers = [{ id: "1", handle: "alice", display_name: "Alice Smith", avatar_url: null }]

    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(mockUsers),
    })
    vi.stubGlobal("fetch", mockFetch)

    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement

    // Type @ali
    inputElement.value = "@ali"
    inputElement.selectionStart = 4
    inputElement.dispatchEvent(new Event("input"))

    // Wait for debounce and fetch
    await vi.advanceTimersByTimeAsync(200)

    await vi.waitFor(() => {
      expect(dropdownElement.style.display).toBe("block")
    })

    // Simulate Enter key to select first result
    inputElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }))

    expect(inputElement.value).toBe("@alice ")
  })

  it("navigates dropdown with arrow keys", async () => {
    // Users are sorted alphabetically by handle: alex < alice (e < i)
    const mockUsers = [
      { id: "1", handle: "alice", display_name: "Alice Smith", avatar_url: null },
      { id: "2", handle: "alex", display_name: "Alex Jones", avatar_url: null },
    ]

    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(mockUsers),
    })
    vi.stubGlobal("fetch", mockFetch)

    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement

    // Type @a
    inputElement.value = "@a"
    inputElement.selectionStart = 2
    inputElement.dispatchEvent(new Event("input"))

    await vi.advanceTimersByTimeAsync(200)

    await vi.waitFor(() => {
      expect(dropdownElement.style.display).toBe("block")
    })

    // First item should be selected by default (alex comes before alice alphabetically)
    expect(dropdownElement.querySelector(".mention-item-selected")?.innerHTML).toContain("alex")

    // Press down arrow
    inputElement.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown" }))

    // Second item should now be selected
    expect(dropdownElement.querySelector(".mention-item-selected")?.innerHTML).toContain("alice")

    // Press up arrow
    inputElement.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp" }))

    // First item should be selected again
    expect(dropdownElement.querySelector(".mention-item-selected")?.innerHTML).toContain("alex")
  })

  it("closes dropdown on Escape key", async () => {
    const mockUsers = [{ id: "1", handle: "alice", display_name: "Alice Smith", avatar_url: null }]

    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(mockUsers),
    })
    vi.stubGlobal("fetch", mockFetch)

    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement

    // Type @a
    inputElement.value = "@a"
    inputElement.selectionStart = 2
    inputElement.dispatchEvent(new Event("input"))

    await vi.advanceTimersByTimeAsync(200)

    await vi.waitFor(() => {
      expect(dropdownElement.style.display).toBe("block")
    })

    // Press Escape
    inputElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }))

    expect(dropdownElement.style.display).toBe("none")
  })

  it("handles fetch errors gracefully", async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error("Network error"))
    vi.stubGlobal("fetch", mockFetch)

    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement

    // Type @test
    inputElement.value = "@test"
    inputElement.selectionStart = 5
    inputElement.dispatchEvent(new Event("input"))

    await vi.advanceTimersByTimeAsync(200)

    // Should not throw and dropdown should remain closed
    expect(dropdownElement.style.display).toBe("none")
  })

  it("filters cached results immediately without waiting for server", async () => {
    const mockUsers = [
      { id: "1", handle: "alice", display_name: "Alice Smith", avatar_url: null },
      { id: "2", handle: "bob", display_name: "Bob Jones", avatar_url: null },
    ]

    // Set up fetch to return results but with a delay
    const mockFetch = vi.fn().mockImplementation(() => {
      return new Promise((resolve) => {
        setTimeout(() => {
          resolve({
            ok: true,
            json: () => Promise.resolve(mockUsers),
          })
        }, 100)
      })
    })
    vi.stubGlobal("fetch", mockFetch)

    const inputElement = document.querySelector("[data-mention-autocomplete-target='input']") as HTMLTextAreaElement
    const dropdownElement = document.querySelector(
      "[data-mention-autocomplete-target='dropdown']"
    ) as HTMLElement

    // First search to populate cache
    inputElement.value = "@a"
    inputElement.selectionStart = 2
    inputElement.dispatchEvent(new Event("input"))

    // Wait for server response to populate cache
    await vi.advanceTimersByTimeAsync(300)

    await vi.waitFor(() => {
      expect(dropdownElement.innerHTML).toContain("alice")
    })

    // Close dropdown
    inputElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }))
    expect(dropdownElement.style.display).toBe("none")

    // Now type again - should show cached results immediately
    inputElement.value = "@ali"
    inputElement.selectionStart = 4
    inputElement.dispatchEvent(new Event("input"))

    // Check immediately (before debounce/fetch) - cached results should show
    expect(dropdownElement.style.display).toBe("block")
    expect(dropdownElement.innerHTML).toContain("alice")
    // Bob shouldn't match "ali"
    expect(dropdownElement.innerHTML).not.toContain("bob")
  })
})
