import { Controller } from "@hotwired/stimulus"

export default class DecisionSubtypeController extends Controller {
  static targets = ["subtypeInput", "voteBtn", "executiveBtn", "decisionMakerSection", "deadlineLabel"]

  declare readonly subtypeInputTarget: HTMLInputElement
  declare readonly voteBtnTarget: HTMLButtonElement
  declare readonly executiveBtnTarget: HTMLButtonElement
  declare readonly hasDecisionMakerSectionTarget: boolean
  declare readonly decisionMakerSectionTarget: HTMLElement
  declare readonly hasDeadlineLabelTarget: boolean
  declare readonly deadlineLabelTarget: HTMLElement

  selectVote(): void {
    this.subtypeInputTarget.value = "vote"
    this.voteBtnTarget.className = "pulse-action-btn"
    this.executiveBtnTarget.className = "pulse-action-btn-secondary"
    if (this.hasDecisionMakerSectionTarget) {
      this.decisionMakerSectionTarget.style.display = "none"
    }
    if (this.hasDeadlineLabelTarget) {
      this.deadlineLabelTarget.textContent = "When should voting close?"
    }
  }

  selectExecutive(): void {
    this.subtypeInputTarget.value = "executive"
    this.voteBtnTarget.className = "pulse-action-btn-secondary"
    this.executiveBtnTarget.className = "pulse-action-btn"
    if (this.hasDecisionMakerSectionTarget) {
      this.decisionMakerSectionTarget.style.display = ""
    }
    if (this.hasDeadlineLabelTarget) {
      this.deadlineLabelTarget.textContent = "When should this decision close?"
    }
  }
}
