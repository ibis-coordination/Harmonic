import { Controller } from "@hotwired/stimulus"

/**
 * HeaderSearchController handles the global search bar in the header.
 *
 * When the user focuses on the search input, if they're within a specific
 * studio/scene context, it auto-populates the input with `studio:handle ` or
 * `scene:handle ` to scope the search to that collective. The user can remove
 * this prefix to search across all accessible collectives.
 *
 * Usage:
 * <div data-controller="header-search"
 *      data-header-search-collective-handle-value="my-studio"
 *      data-header-search-collective-type-value="studio"
 *      data-header-search-collective-name-value="My Studio">
 *   <form data-header-search-target="form">
 *     <input data-header-search-target="input"
 *            data-action="focus->header-search#onFocus blur->header-search#onBlur" />
 *   </form>
 * </div>
 */
export default class HeaderSearchController extends Controller<HTMLElement> {
  static targets = ["form", "input"]
  static values = {
    collectiveHandle: String,
    collectiveType: String,
    collectiveName: String,
  }

  declare readonly formTarget: HTMLFormElement
  declare readonly inputTarget: HTMLInputElement
  declare collectiveHandleValue: string
  declare collectiveTypeValue: string
  declare collectiveNameValue: string

  private hasAutoPopulated = false

  connect(): void {
    // Nothing to do on connect
  }

  /**
   * Build the auto-populated prefix based on collective type and handle.
   * Returns `studio:handle` or `scene:handle`.
   */
  private buildPrefix(): string | null {
    const handle = this.collectiveHandleValue
    const type = this.collectiveTypeValue

    if (!handle || !type) {
      return null
    }

    // Type should be "studio" or "scene"
    return `${type}:${handle}`
  }

  /**
   * When the input gains focus:
   * - If empty and we have a collective context, auto-populate with `studio:handle ` or `scene:handle `
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
}
