import { Controller } from "@hotwired/stimulus"

export default class AiAgentModeController extends Controller {
  static targets = ["externalOnly", "internalOnly"]

  declare readonly externalOnlyTargets: HTMLElement[]
  declare readonly internalOnlyTargets: HTMLElement[]

  connect(): void {
    this.updateVisibility()
  }

  updateVisibility(): void {
    const selectedMode = this.getSelectedMode()
    const isExternal = selectedMode === "external"
    const isInternal = selectedMode === "internal"

    this.externalOnlyTargets.forEach((el) => {
      el.style.display = isExternal ? "block" : "none"
    })

    this.internalOnlyTargets.forEach((el) => {
      el.style.display = isInternal ? "block" : "none"
    })
  }

  private getSelectedMode(): string {
    const selectedRadio = this.element.querySelector(
      'input[name="mode"]:checked'
    ) as HTMLInputElement
    return selectedRadio?.value || "external"
  }
}
