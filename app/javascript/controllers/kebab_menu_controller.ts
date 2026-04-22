import { Controller } from "@hotwired/stimulus"

// Simple kebab menu controller using <details> with outside-click dismissal.
// Usage:
//   <details data-controller="kebab-menu">
//     <summary>...</summary>
//     <div>menu content</div>
//   </details>
export default class KebabMenuController extends Controller {
  private boundClose: (event: Event) => void

  constructor(context: any) {
    super(context)
    this.boundClose = this.closeOnOutsideClick.bind(this)
  }

  connect(): void {
    document.addEventListener("click", this.boundClose)
  }

  disconnect(): void {
    document.removeEventListener("click", this.boundClose)
  }

  private closeOnOutsideClick(event: Event): void {
    const details = this.element as HTMLDetailsElement
    if (details.open && !details.contains(event.target as Node)) {
      details.open = false
    }
  }
}
