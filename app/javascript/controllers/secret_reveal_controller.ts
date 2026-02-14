import { Controller } from "@hotwired/stimulus"

export default class SecretRevealController extends Controller {
  static targets = ["hidden", "visible"]

  declare readonly hiddenTargets: HTMLElement[]
  declare readonly visibleTargets: HTMLElement[]

  reveal(): void {
    this.hiddenTargets.forEach((el) => (el.style.display = "none"))
    this.visibleTargets.forEach((el) => (el.style.display = "inline"))
  }

  hide(): void {
    this.visibleTargets.forEach((el) => (el.style.display = "none"))
    this.hiddenTargets.forEach((el) => (el.style.display = "inline"))
  }
}
