import { Controller } from "@hotwired/stimulus"

export default class TabsController extends Controller {
  static targets = ["tab", "panel"]

  declare readonly tabTargets: HTMLElement[]
  declare readonly panelTargets: HTMLElement[]

  show(event: Event): void {
    const target = event.currentTarget as HTMLElement
    const index = parseInt(target.dataset.tabsIndexParam || "0", 10)

    this.tabTargets.forEach((tab, i) => {
      if (i === index) {
        tab.className = "pulse-action-btn pulse-action-btn-primary"
      } else {
        tab.className = "pulse-action-btn-secondary"
      }
    })

    this.panelTargets.forEach((panel, i) => {
      panel.style.display = i === index ? "" : "none"
    })
  }
}
