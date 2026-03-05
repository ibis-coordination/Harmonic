import { Controller } from "@hotwired/stimulus"

/**
 * HeaderSearchController handles the global search bar in the header.
 *
 * When the user focuses on the search input, if they're within a specific
 * collective context, it auto-populates the input with `collective:handle `
 * to scope the search to that collective. The user can remove
 * this prefix to search across all accessible collectives.
 *
 * On mobile (<=768px), the search bar collapses to an icon-only button.
 * Tapping the icon expands the search as an overlay. Escape or click-outside
 * collapses it back.
 *
 * Usage:
 * <div data-controller="header-search"
 *      data-header-search-collective-handle-value="my-collective"
 *      data-header-search-collective-name-value="My Collective"
 *      class="header-search-wrapper">
 *   <button data-header-search-target="toggle"
 *           data-action="click->header-search#toggleMobileSearch">search icon</button>
 *   <form data-header-search-target="form">
 *     <input data-header-search-target="input"
 *            data-action="focus->header-search#onFocus blur->header-search#onBlur keydown.esc->header-search#collapseMobileSearch" />
 *   </form>
 * </div>
 */
export default class HeaderSearchController extends Controller<HTMLElement> {
  static targets = ["form", "input", "toggle"]
  static values = {
    collectiveHandle: String,
    collectiveName: String,
  }

  declare readonly formTarget: HTMLFormElement
  declare readonly inputTarget: HTMLInputElement
  declare readonly hasToggleTarget: boolean
  declare collectiveHandleValue: string
  declare collectiveNameValue: string

  private hasAutoPopulated = false
  private boundClickOutside: ((event: Event) => void) | null = null

  connect(): void {
    this.boundClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener("click", this.boundClickOutside)
  }

  disconnect(): void {
    if (this.boundClickOutside) {
      document.removeEventListener("click", this.boundClickOutside)
    }
  }

  /**
   * Build the auto-populated prefix based on collective handle.
   * Returns `collective:handle`.
   */
  private buildPrefix(): string | null {
    const handle = this.collectiveHandleValue

    if (!handle) {
      return null
    }

    return `collective:${handle}`
  }

  /**
   * When the input gains focus:
   * - If empty and we have a collective context, auto-populate with `collective:handle `
   * - Move cursor to end of input
   */
  onFocus(): void {
    const input = this.inputTarget
    const prefix = this.buildPrefix()

    // Only auto-populate once per page load, when input is empty
    if (!this.hasAutoPopulated && input.value.trim() === "" && prefix) {
      input.value = `${prefix} `
      this.hasAutoPopulated = true

      // Move cursor to end
      requestAnimationFrame(() => {
        input.setSelectionRange(input.value.length, input.value.length)
      })
    }
  }

  /**
   * When the input loses focus:
   * - If it's only the auto-populated prefix, clear it
   */
  onBlur(): void {
    const input = this.inputTarget
    const prefix = this.buildPrefix()

    // If user hasn't added any search terms, clear the auto-populated prefix
    if (prefix && input.value.trim() === prefix) {
      input.value = ""
      this.hasAutoPopulated = false
    }
  }

  /**
   * Focus the input when the search icon is clicked
   */
  focusInput(): void {
    this.inputTarget.focus()
  }

  // --- Mobile search toggle ---

  private isMobile(): boolean {
    return window.innerWidth <= 768
  }

  private isExpanded(): boolean {
    return this.element.classList.contains("header-search-expanded")
  }

  toggleMobileSearch(): void {
    if (!this.isMobile()) return

    if (this.isExpanded()) {
      this.collapseMobileSearch()
    } else {
      this.expandMobileSearch()
    }
  }

  private expandMobileSearch(): void {
    this.element.classList.add("header-search-expanded")
    requestAnimationFrame(() => {
      this.inputTarget.focus()
    })
  }

  collapseMobileSearch(): void {
    if (!this.isMobile() || !this.isExpanded()) return

    this.element.classList.remove("header-search-expanded")
    this.inputTarget.blur()

    const prefix = this.buildPrefix()
    if (prefix && this.inputTarget.value.trim() === prefix) {
      this.inputTarget.value = ""
      this.hasAutoPopulated = false
    }
  }

  private handleClickOutside(event: Event): void {
    if (!this.isMobile() || !this.isExpanded()) return

    const target = event.target as Node
    if (!this.element.contains(target)) {
      this.collapseMobileSearch()
    }
  }
}
