import { Controller } from "@hotwired/stimulus"

// Whole-card click navigation. Wire on a feed-item <article> with the target
// path in the URL value; clicking anywhere on the card sends the browser to
// that path UNLESS the click originated inside an interactive child element
// (link, button, form input, anything explicitly marked `data-no-navigate`),
// the user used a modifier key (cmd/ctrl/shift/middle-click — they want a
// new tab or new window), or there's a non-empty text selection (drag-to-
// select shouldn't eat the user's selection on mouseup).
//
//   <article data-controller="card-navigate"
//            data-card-navigate-url-value="/n/abc12345"
//            data-action="click->card-navigate#navigate keydown->card-navigate#keydown"
//            tabindex="0" role="link" aria-label="View ...">
//     ...
//   </article>
//
// `data-no-navigate` is the explicit opt-out (used by the card-expand
// "Show more" button so it can stop propagation cleanly). The
// INTERACTIVE_TAGS list covers the implicit cases — anchors, buttons, form
// controls, <summary>. Without these guards a click on the title link would
// both follow the link AND fire this navigation (same URL but a wasted reload).
const INTERACTIVE_TAGS = new Set([
  "A", "BUTTON", "INPUT", "TEXTAREA", "SELECT", "LABEL", "FORM", "SUMMARY",
])

export default class extends Controller {
  static values = { url: String }
  declare readonly urlValue: string

  navigate(event: MouseEvent): void {
    if (!this.urlValue) return
    if (this.targetIsInteractive(event.target)) return
    // Drag-to-select-text and release: a click fires on the end target. Don't
    // eat the user's selection by navigating away. getSelection() can be null
    // in some browsers/contexts — guard accordingly.
    if (window.getSelection()?.toString()) return

    // Right-click (button 2) opens the context menu; never navigate.
    if (event.button === 2) return

    // Mouse buttons OTHER than left, OR left + any modifier — emulate
    // native <a> behavior: open in a new tab. Without this branch, cmd-click
    // would silently do nothing (no anchor for the browser to act on).
    const newTab =
      event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0
    if (newTab) {
      window.open(this.urlValue, "_blank", "noopener")
      return
    }

    window.location.href = this.urlValue
  }

  // Keyboard equivalent of `navigate`. Stimulus matches `data-action=
  // "keydown->card-navigate#keydown"`. Enter/Space activate the link, same
  // as a native <a>. Cmd/Ctrl+Enter opens in a new tab, matching anchor
  // behavior. ' ' and 'Spacebar' (IE/older Edge) both handled.
  keydown(event: KeyboardEvent): void {
    if (!this.urlValue) return
    if (event.key !== "Enter" && event.key !== " " && event.key !== "Spacebar") return
    // If focus is inside a child interactive element, let that element handle
    // the keypress (e.g., Enter on a <button> should activate the button).
    if (this.targetIsInteractive(event.target)) return
    event.preventDefault()

    if (event.metaKey || event.ctrlKey) {
      window.open(this.urlValue, "_blank", "noopener")
    } else {
      window.location.href = this.urlValue
    }
  }

  private targetIsInteractive(target: EventTarget | null): boolean {
    if (!(target instanceof HTMLElement)) return false
    if (target.closest("[data-no-navigate]")) return true

    // closest() walks up through ancestors stopping at the first match;
    // bounded by this.element so a card-navigate on a parent doesn't fire
    // from a click inside a nested interactive element on a sibling.
    let node: HTMLElement | null = target
    while (node && node !== this.element) {
      if (INTERACTIVE_TAGS.has(node.tagName)) return true
      node = node.parentElement
    }
    return false
  }
}
