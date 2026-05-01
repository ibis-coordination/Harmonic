import { Controller } from "@hotwired/stimulus"

export default class DecisionSubtypeController extends Controller {
  static targets = ["subtypeInput", "voteBtn", "executiveBtn", "lotteryBtn", "decisionMakerSection", "deadlineLabel"]

  declare readonly subtypeInputTarget: HTMLInputElement
  declare readonly voteBtnTarget: HTMLButtonElement
  declare readonly executiveBtnTarget: HTMLButtonElement
  declare readonly hasLotteryBtnTarget: boolean
  declare readonly lotteryBtnTarget: HTMLButtonElement
  declare readonly hasDecisionMakerSectionTarget: boolean
  declare readonly decisionMakerSectionTarget: HTMLElement
  declare readonly hasDeadlineLabelTarget: boolean
  declare readonly deadlineLabelTarget: HTMLElement

  selectVote(): void {
    this.subtypeInputTarget.value = "vote"
    this.setActiveButton(this.voteBtnTarget)
    if (this.hasDecisionMakerSectionTarget) {
      this.decisionMakerSectionTarget.style.display = "none"
    }
    if (this.hasDeadlineLabelTarget) {
      this.deadlineLabelTarget.textContent = "When should voting close?"
    }
  }

  selectExecutive(): void {
    this.subtypeInputTarget.value = "executive"
    this.setActiveButton(this.executiveBtnTarget)
    if (this.hasDecisionMakerSectionTarget) {
      this.decisionMakerSectionTarget.style.display = ""
    }
    if (this.hasDeadlineLabelTarget) {
      this.deadlineLabelTarget.textContent = "When should this decision close?"
    }
  }

  selectLottery(): void {
    this.subtypeInputTarget.value = "lottery"
    this.setActiveButton(this.lotteryBtnTarget)
    if (this.hasDecisionMakerSectionTarget) {
      this.decisionMakerSectionTarget.style.display = "none"
    }
    if (this.hasDeadlineLabelTarget) {
      this.deadlineLabelTarget.textContent = "When should the lottery be drawn?"
    }
  }

  private setActiveButton(active: HTMLButtonElement): void {
    this.voteBtnTarget.className = "pulse-action-btn-secondary"
    this.executiveBtnTarget.className = "pulse-action-btn-secondary"
    if (this.hasLotteryBtnTarget) {
      this.lotteryBtnTarget.className = "pulse-action-btn-secondary"
    }
    active.className = "pulse-action-btn"
  }
}
