import { Controller } from "@hotwired/stimulus"

/**
 * HeaderSearchController handles the global search bar in the header.
 *
 * When the user focuses on the search input, if they're within a specific
 * studio/scene context, it auto-populates the input with `in:handle ` to
 * scope the search to that superagent. The user can remove this prefix
 * to search across all accessible superagents.
 *
 * Usage:
 * <div data-controller="header-search"
 *      data-header-search-superagent-handle-value="my-studio"
 *      data-header-search-superagent-name-value="My Studio">
 *   <form data-header-search-target="form">
 *     <input data-header-search-target="input"
 *            data-action="focus->header-search#onFocus blur->header-search#onBlur" />
 *   </form>
 * </div>
 */
export default class HeaderSearchController extends Controller<HTMLElement> {
  static targets = ["form", "input"]
  static values = {
    superagentHandle: String,
    superagentName: String,
  }

  declare readonly formTarget: HTMLFormElement
  declare readonly inputTarget: HTMLInputElement
  declare superagentHandleValue: string
  declare superagentNameValue: string

  private hasAutoPopulated = false

  connect(): void {
    // Nothing to do on connect
  }

  /**
   * When the input gains focus:
   * - If empty and we have a superagent context, auto-populate with `in:handle `
   * - Move cursor to end of input
   */
  onFocus(): void {
    const input = this.inputTarget
    const handle = this.superagentHandleValue

    // Only auto-populate once per page load, when input is empty
    if (!this.hasAutoPopulated && input.value.trim() === "" && handle) {
      input.value = `in:${handle} `
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
    const handle = this.superagentHandleValue

    // If user hasn't added any search terms, clear the auto-populated prefix
    if (handle && input.value.trim() === `in:${handle}`) {
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
