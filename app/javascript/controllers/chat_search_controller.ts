import { Controller } from "@hotwired/stimulus"

interface UserResult {
  id: string
  handle: string
  display_name: string
  avatar_url: string | null
}

/**
 * ChatSearchController provides a "new conversation" search dropdown
 * in the chat sidebar. Clicking the + button opens a search input that
 * queries the autocomplete endpoint and navigates to /chat/:handle on select.
 */
export default class ChatSearchController extends Controller<HTMLElement> {
  static targets = ["button", "panel", "input", "results"]
  static values = {
    autocompleteUrl: String,
  }

  declare readonly buttonTarget: HTMLElement
  declare readonly panelTarget: HTMLElement
  declare readonly inputTarget: HTMLInputElement
  declare readonly resultsTarget: HTMLElement

  declare autocompleteUrlValue: string

  private isOpen = false
  private searchTimeout: number | null = null
  private resultsList: UserResult[] = []
  private selectedIndex = 0

  toggle(): void {
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  search(): void {
    if (this.searchTimeout) clearTimeout(this.searchTimeout)
    this.searchTimeout = window.setTimeout(() => this.doSearch(), 150)
  }

  handleKeydown(event: KeyboardEvent): void {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        if (this.resultsList.length > 0) {
          this.selectedIndex = (this.selectedIndex + 1) % this.resultsList.length
          this.renderResults()
        }
        break
      case "ArrowUp":
        event.preventDefault()
        if (this.resultsList.length > 0) {
          this.selectedIndex = (this.selectedIndex - 1 + this.resultsList.length) % this.resultsList.length
          this.renderResults()
        }
        break
      case "Enter":
        event.preventDefault()
        this.selectResult(this.selectedIndex)
        break
      case "Escape":
        this.close()
        break
    }
  }

  clickResult(event: Event): void {
    const target = (event.target as HTMLElement).closest("[data-index]") as HTMLElement
    if (!target) return
    const index = parseInt(target.dataset.index ?? "0", 10)
    this.selectResult(index)
  }

  private open(): void {
    this.isOpen = true
    this.panelTarget.style.display = ""
    this.inputTarget.value = ""
    this.resultsList = []
    this.resultsTarget.innerHTML = ""
    requestAnimationFrame(() => this.inputTarget.focus())
    document.addEventListener("click", this.handleClickOutside)
  }

  private close(): void {
    this.isOpen = false
    this.panelTarget.style.display = "none"
    document.removeEventListener("click", this.handleClickOutside)
  }

  private handleClickOutside = (event: Event): void => {
    if (!this.element.contains(event.target as Node)) {
      this.close()
    }
  }

  private async doSearch(): Promise<void> {
    const query = this.inputTarget.value.trim()
    const url = `${this.autocompleteUrlValue}?q=${encodeURIComponent(query)}`

    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      })
      if (!response.ok) return
      this.resultsList = await response.json()
      this.selectedIndex = 0
      this.renderResults()
    } catch {
      // Silent fail
    }
  }

  private selectResult(index: number): void {
    if (index < 0 || index >= this.resultsList.length) return
    const user = this.resultsList[index]
    window.location.href = `/chat/${user.handle}`
  }

  private renderResults(): void {
    if (this.resultsList.length === 0) {
      const query = this.inputTarget.value.trim()
      this.resultsTarget.innerHTML = query
        ? `<div style="padding: 8px 10px; color: var(--color-fg-muted); font-size: 13px;">No users found</div>`
        : ""
      return
    }

    this.resultsTarget.innerHTML = this.resultsList
      .map(
        (user, index) => `
        <div class="pulse-nav-item${index === this.selectedIndex ? " active" : ""}"
             data-index="${index}"
             data-action="click->chat-search#clickResult"
             style="display: flex; align-items: center; gap: 8px; padding: 6px 10px; font-size: 13px; cursor: pointer; border-radius: 6px; margin-bottom: 2px;">
          ${this.renderAvatar(user)}
          <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            ${this.escapeHtml(user.display_name)}
          </span>
        </div>
      `,
      )
      .join("")
  }

  private renderAvatar(user: UserResult): string {
    if (user.avatar_url) {
      return `<img src="${this.escapeHtml(user.avatar_url)}" alt="" style="width: 24px; height: 24px; border-radius: 50%;" />`
    }
    const initials = this.getInitials(user.display_name)
    return `<span style="width: 24px; height: 24px; border-radius: 50%; background: var(--color-canvas-subtle); display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: 600;">${initials}</span>`
  }

  private getInitials(name: string): string {
    const parts = name.split(/[\s\-_]+/)
    if (parts.length >= 2) {
      return `${parts[0]?.[0] ?? ""}${parts[1]?.[0] ?? ""}`.toUpperCase()
    }
    return (name.slice(0, 2) || "?").toUpperCase()
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
