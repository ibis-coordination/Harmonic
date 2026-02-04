import { Controller } from "@hotwired/stimulus"

export default class SubagentModeController extends Controller {
  static targets = ["externalOnly"]

  declare readonly externalOnlyTargets: HTMLElement[]

  connect(): void {
    this.updateVisibility()
  }

  updateVisibility(): void {
    const selectedMode = this.getSelectedMode()
    const isExternal = selectedMode === "external"

    this.externalOnlyTargets.forEach((el) => {
      el.style.display = isExternal ? "block" : "none"
    })
  }

  private getSelectedMode(): string {
    const selectedRadio = this.element.querySelector(
      'input[name="mode"]:checked'
    ) as HTMLInputElement
    return selectedRadio?.value || "external"
  }
}
