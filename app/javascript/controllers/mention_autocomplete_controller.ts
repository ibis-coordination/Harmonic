import { Controller } from "@hotwired/stimulus"

interface UserResult {
  id: string
  handle: string
  display_name: string
  avatar_url: string | null
}

/**
 * MentionAutocompleteController provides @ mention autocomplete functionality for text inputs.
 *
 * Features:
 * - Client-side filtering of cached results for instant feedback
 * - Background server fetches to update the cache
 * - Loading spinner only shown when no cached results are available
 *
 * Usage:
 * <div data-controller="mention-autocomplete"
 *      data-mention-autocomplete-studio-path-value="/studios/my-studio">
 *   <textarea data-mention-autocomplete-target="input"></textarea>
 *   <div data-mention-autocomplete-target="dropdown" class="mention-dropdown"></div>
 * </div>
 */
export default class MentionAutocompleteController extends Controller<HTMLElement> {
  static targets = ["input", "dropdown"]
  static values = {
    studioPath: { type: String, default: "" },
  }

  declare readonly inputTarget: HTMLTextAreaElement | HTMLInputElement
  declare readonly dropdownTarget: HTMLElement
  declare readonly hasInputTarget: boolean
  declare readonly hasDropdownTarget: boolean
  declare studioPathValue: string

  private results: UserResult[] = []
  private cachedUsers: UserResult[] = []
  private selectedIndex = 0
  private mentionStart = -1
  private searchTimeout: number | null = null
  private isOpen = false
  private mirrorElement: HTMLDivElement | null = null
  private currentQuery = ""
  private pendingFetch: AbortController | null = null

  connect(): void {
    if (this.hasInputTarget) {
      this.inputTarget.addEventListener("input", this.handleInput.bind(this))
      this.inputTarget.addEventListener("keydown", this.handleKeydown.bind(this) as EventListener)
      this.inputTarget.addEventListener("blur", this.handleBlur.bind(this))
      this.inputTarget.addEventListener("scroll", this.handleScroll.bind(this))
    }
    if (this.hasDropdownTarget) {
      this.dropdownTarget.style.display = "none"
    }
    this.createMirrorElement()
  }

  disconnect(): void {
    if (this.searchTimeout !== null) {
      clearTimeout(this.searchTimeout)
    }
    if (this.pendingFetch) {
      this.pendingFetch.abort()
    }
    this.removeMirrorElement()
  }

  private handleInput(): void {
    const cursorPosition = this.inputTarget.selectionStart ?? 0
    const text = this.inputTarget.value
    const beforeCursor = text.substring(0, cursorPosition)

    // Find the start of a potential mention
    const mentionMatch = beforeCursor.match(/@([a-zA-Z0-9_-]*)$/)

    if (mentionMatch) {
      this.mentionStart = beforeCursor.length - mentionMatch[0].length
      const query = mentionMatch[1]
      this.currentQuery = query.toLowerCase()

      // Position dropdown
      this.positionDropdownAtCaret()

      // Cancel any pending debounced search
      if (this.searchTimeout !== null) {
        clearTimeout(this.searchTimeout)
      }

      // First, try to filter cached results immediately
      const filteredResults = this.filterCachedResults(this.currentQuery)

      if (filteredResults.length > 0) {
        // Show cached results immediately (no loading spinner)
        this.results = filteredResults
        this.selectedIndex = 0
        this.renderDropdown()
        this.open()
      } else if (this.cachedUsers.length === 0) {
        // No cache at all - show loading
        this.showLoading()
      } else {
        // Have cache but no matches - show no results
        this.results = []
        this.renderNoResults()
        this.open()
      }

      // Always fetch from server in background to update cache
      this.searchTimeout = window.setTimeout(() => {
        this.searchInBackground(query)
      }, 150)
    } else {
      this.close()
    }
  }

  /**
   * Filter cached users by query (searches handle and display_name)
   * If query is empty, returns first 10 users sorted alphabetically by handle
   */
  private filterCachedResults(query: string): UserResult[] {
    if (this.cachedUsers.length === 0) {
      return []
    }

    // If no query, return first 10 users sorted alphabetically
    if (!query) {
      return [...this.cachedUsers].sort((a, b) => a.handle.localeCompare(b.handle)).slice(0, 10)
    }

    const lowerQuery = query.toLowerCase()
    return this.cachedUsers
      .filter(
        (user) =>
          user.handle.toLowerCase().includes(lowerQuery) || user.display_name.toLowerCase().includes(lowerQuery)
      )
      .sort((a, b) => a.handle.localeCompare(b.handle))
      .slice(0, 10)
  }

  private handleKeydown(event: KeyboardEvent): void {
    if (!this.isOpen) return

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.selectNext()
        break
      case "ArrowUp":
        event.preventDefault()
        this.selectPrevious()
        break
      case "Enter":
        if (this.results.length > 0) {
          event.preventDefault()
          this.selectResult(this.selectedIndex)
        }
        break
      case "Tab":
        if (this.results.length > 0) {
          event.preventDefault()
          this.selectResult(this.selectedIndex)
        }
        break
      case "Escape":
        event.preventDefault()
        this.close()
        break
    }
  }

  private handleBlur(): void {
    // Delay close to allow click events on dropdown items
    setTimeout(() => {
      this.close()
    }, 200)
  }

  private handleScroll(): void {
    // Reposition dropdown when textarea scrolls
    if (this.isOpen) {
      this.positionDropdownAtCaret()
    }
  }

  private showLoading(): void {
    if (!this.hasDropdownTarget) return

    this.dropdownTarget.innerHTML = `
      <div class="mention-loading">
        <span class="mention-spinner"></span>
        <span>Searching...</span>
      </div>
    `
    this.open()
  }

  /**
   * Fetch results from server in background and update cache
   */
  private async searchInBackground(query: string): Promise<void> {
    // Abort any pending fetch
    if (this.pendingFetch) {
      this.pendingFetch.abort()
    }

    this.pendingFetch = new AbortController()

    try {
      const basePath = this.studioPathValue || ""
      const url = `${basePath}/autocomplete/users?q=${encodeURIComponent(query)}`

      const response = await fetch(url, {
        headers: {
          Accept: "application/json",
        },
        credentials: "same-origin",
        signal: this.pendingFetch.signal,
      })

      if (!response.ok) {
        return
      }

      const serverResults: UserResult[] = await response.json()

      // Update cache with server results (merge with existing)
      this.updateCache(serverResults)

      // Only update display if query hasn't changed
      if (query.toLowerCase() === this.currentQuery) {
        // Re-filter with updated cache
        const filteredResults = this.filterCachedResults(this.currentQuery)

        this.results = filteredResults
        this.selectedIndex = Math.min(this.selectedIndex, Math.max(0, this.results.length - 1))

        if (this.results.length > 0) {
          this.renderDropdown()
        } else {
          this.renderNoResults()
        }
      }
    } catch (error) {
      // Ignore abort errors
      if (error instanceof Error && error.name === "AbortError") {
        return
      }
      // On other errors, close if we have no cached results to show
      if (this.cachedUsers.length === 0) {
        this.close()
      }
    } finally {
      this.pendingFetch = null
    }
  }

  /**
   * Update the cache with new results from server
   * Merges with existing cache to build up a comprehensive list
   */
  private updateCache(newResults: UserResult[]): void {
    // Create a map of existing cached users by ID
    const cacheMap = new Map(this.cachedUsers.map((user) => [user.id, user]))

    // Add/update with new results
    for (const user of newResults) {
      cacheMap.set(user.id, user)
    }

    // Convert back to array
    this.cachedUsers = Array.from(cacheMap.values())
  }

  private renderDropdown(): void {
    if (!this.hasDropdownTarget) return

    this.dropdownTarget.innerHTML = this.results
      .map(
        (user, index) => `
        <div class="mention-item ${index === this.selectedIndex ? "mention-item-selected" : ""}"
             data-index="${index}"
             data-action="click->mention-autocomplete#clickResult">
          <span class="mention-avatar">
            ${user.avatar_url ? `<img src="${user.avatar_url}" alt="" />` : this.getInitials(user.display_name)}
          </span>
          <span class="mention-info">
            <span class="mention-display-name">${this.escapeHtml(user.display_name)}</span>
            <span class="mention-handle">@${this.escapeHtml(user.handle)}</span>
          </span>
        </div>
      `
      )
      .join("")
  }

  private renderNoResults(): void {
    if (!this.hasDropdownTarget) return

    this.dropdownTarget.innerHTML = `
      <div class="mention-no-results">
        No users found
      </div>
    `
  }

  /**
   * Creates a mirror element used to calculate caret position in textarea
   */
  private createMirrorElement(): void {
    this.mirrorElement = document.createElement("div")
    this.mirrorElement.style.cssText = `
      position: absolute;
      top: -9999px;
      left: -9999px;
      visibility: hidden;
      white-space: pre-wrap;
      word-wrap: break-word;
    `
    document.body.appendChild(this.mirrorElement)
  }

  private removeMirrorElement(): void {
    if (this.mirrorElement && this.mirrorElement.parentNode) {
      this.mirrorElement.parentNode.removeChild(this.mirrorElement)
      this.mirrorElement = null
    }
  }

  /**
   * Gets the pixel position of a character index within the textarea
   */
  private getCaretCoordinates(position: number): { top: number; left: number } {
    if (!this.mirrorElement || !this.hasInputTarget) {
      return { top: 0, left: 0 }
    }

    const input = this.inputTarget as HTMLTextAreaElement
    const style = window.getComputedStyle(input)

    // Copy all relevant styles from textarea to mirror
    const properties = [
      "fontFamily",
      "fontSize",
      "fontWeight",
      "fontStyle",
      "letterSpacing",
      "textTransform",
      "wordSpacing",
      "textIndent",
      "lineHeight",
      "paddingTop",
      "paddingRight",
      "paddingBottom",
      "paddingLeft",
      "borderTopWidth",
      "borderRightWidth",
      "borderBottomWidth",
      "borderLeftWidth",
      "boxSizing",
    ]

    properties.forEach((prop) => {
      this.mirrorElement!.style.setProperty(this.camelToKebab(prop), style.getPropertyValue(this.camelToKebab(prop)))
    })

    // Critical: match width exactly and handle word wrapping like textarea
    this.mirrorElement.style.width = style.width
    this.mirrorElement.style.whiteSpace = "pre-wrap"
    this.mirrorElement.style.wordWrap = "break-word"
    this.mirrorElement.style.overflowWrap = "break-word"

    // Get text up to caret position and escape HTML
    const textBeforeCaret = input.value.substring(0, position)
    const escapedText = textBeforeCaret
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\n/g, "<br>")
      .replace(/ /g, "&nbsp;")

    // Use innerHTML with a marker span for accurate positioning
    this.mirrorElement.innerHTML = escapedText + '<span id="caret-marker">|</span>'

    const caretSpan = this.mirrorElement.querySelector("#caret-marker") as HTMLElement
    if (!caretSpan) {
      return { top: 0, left: 0 }
    }

    // Get position relative to mirror element
    const caretTop = caretSpan.offsetTop
    const caretLeft = caretSpan.offsetLeft

    return { top: caretTop, left: caretLeft }
  }

  private camelToKebab(str: string): string {
    return str.replace(/([a-z])([A-Z])/g, "$1-$2").toLowerCase()
  }

  private positionDropdownAtCaret(): void {
    if (!this.hasDropdownTarget || !this.hasInputTarget) return

    const input = this.inputTarget as HTMLTextAreaElement
    const style = window.getComputedStyle(input)

    // Get caret position at the @ symbol (includes padding from mirror element)
    const caretPos = this.getCaretCoordinates(this.mentionStart)

    // Calculate scroll offset within the textarea
    const scrollTop = input.scrollTop
    const scrollLeft = input.scrollLeft

    // Get line height for positioning below the current line
    const lineHeight = parseInt(style.lineHeight, 10) || parseInt(style.fontSize, 10) * 1.2

    // Calculate position relative to the textarea's top-left corner
    // caretPos already includes padding, so we just need to account for scroll and add line height
    const top = caretPos.top - scrollTop + lineHeight
    const left = caretPos.left - scrollLeft

    // Get textarea's position relative to the container (the dropdown's positioning context)
    const inputOffsetTop = input.offsetTop
    const inputOffsetLeft = input.offsetLeft

    this.dropdownTarget.style.position = "absolute"
    this.dropdownTarget.style.top = `${inputOffsetTop + top}px`
    this.dropdownTarget.style.left = `${inputOffsetLeft + left}px`
    this.dropdownTarget.style.width = "auto"
    this.dropdownTarget.style.minWidth = "200px"
    this.dropdownTarget.style.maxWidth = "300px"
  }

  private open(): void {
    if (!this.hasDropdownTarget) return
    this.dropdownTarget.style.display = "block"
    this.isOpen = true
  }

  private close(): void {
    if (!this.hasDropdownTarget) return
    this.dropdownTarget.style.display = "none"
    this.isOpen = false
    this.results = []
    this.mentionStart = -1
    this.currentQuery = ""
    // Note: we keep cachedUsers for future use
  }

  private selectNext(): void {
    if (this.results.length === 0) return
    this.selectedIndex = (this.selectedIndex + 1) % this.results.length
    this.renderDropdown()
  }

  private selectPrevious(): void {
    if (this.results.length === 0) return
    this.selectedIndex = (this.selectedIndex - 1 + this.results.length) % this.results.length
    this.renderDropdown()
  }

  clickResult(event: Event): void {
    const target = event.currentTarget as HTMLElement
    const index = parseInt(target.dataset.index ?? "0", 10)
    this.selectResult(index)
  }

  private selectResult(index: number): void {
    if (index < 0 || index >= this.results.length) return

    const user = this.results[index]
    const cursorPosition = this.inputTarget.selectionStart ?? 0
    const text = this.inputTarget.value

    // Replace the @mention with the selected handle
    const before = text.substring(0, this.mentionStart)
    const after = text.substring(cursorPosition)
    const mention = `@${user.handle} `

    this.inputTarget.value = before + mention + after

    // Move cursor to after the mention
    const newCursorPosition = this.mentionStart + mention.length
    this.inputTarget.setSelectionRange(newCursorPosition, newCursorPosition)
    this.inputTarget.focus()

    this.close()
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  private getInitials(name: string): string {
    return name
      .split(" ")
      .map((part) => part[0])
      .slice(0, 2)
      .join("")
      .toUpperCase()
  }
}
