import { Controller } from "@hotwired/stimulus"

// Commitment subtype toggle (Action / Calendar Event / Policy).
// Shows/hides the calendar-event-only "When" section and relabels the
// critical-mass and deadline sections per subtype. Policies and actions
// share the same fields and only differ in labels.
export default class CommitmentSubtypeController extends Controller {
  static targets = [
    "subtypeInput",
    "actionBtn",
    "calendarEventBtn",
    "policyBtn",
    "calendarEventFields",
    "criticalMassTitle",
    "criticalMassDescription",
    "criticalMassSuffix",
    "deadlineTitle",
    "deadlineDescription",
    "submitButton",
  ]

  declare readonly subtypeInputTarget: HTMLInputElement
  declare readonly actionBtnTarget: HTMLButtonElement
  declare readonly calendarEventBtnTarget: HTMLButtonElement
  declare readonly policyBtnTarget: HTMLButtonElement
  declare readonly hasCalendarEventFieldsTarget: boolean
  declare readonly calendarEventFieldsTarget: HTMLElement
  declare readonly hasCriticalMassTitleTarget: boolean
  declare readonly criticalMassTitleTarget: HTMLElement
  declare readonly hasCriticalMassDescriptionTarget: boolean
  declare readonly criticalMassDescriptionTarget: HTMLElement
  declare readonly hasCriticalMassSuffixTarget: boolean
  declare readonly criticalMassSuffixTarget: HTMLElement
  declare readonly hasDeadlineTitleTarget: boolean
  declare readonly deadlineTitleTarget: HTMLElement
  declare readonly hasDeadlineDescriptionTarget: boolean
  declare readonly deadlineDescriptionTarget: HTMLElement
  declare readonly hasSubmitButtonTarget: boolean
  declare readonly submitButtonTarget: HTMLInputElement

  selectAction(): void {
    this.subtypeInputTarget.value = "action"
    this.setActiveButton(this.actionBtnTarget)
    this.toggleCalendarEventFields(false)
    this.setCriticalMassCopy("Critical Mass", "How many participants are required for this commitment to take effect?", "participant(s) required")
    this.setDeadlineCopy("Deadline", "When must critical mass be reached?")
    this.setSubmitLabel("Start Commitment")
  }

  selectCalendarEvent(): void {
    this.subtypeInputTarget.value = "calendar_event"
    this.setActiveButton(this.calendarEventBtnTarget)
    this.toggleCalendarEventFields(true)
    this.setCriticalMassCopy("Minimum attendees", "Minimum number of attendees needed for this event to happen.", "attendee(s)")
    this.setDeadlineCopy("RSVP by", "Optional deadline for RSVPs.")
    this.setSubmitLabel("Create Event")
  }

  selectPolicy(): void {
    this.subtypeInputTarget.value = "policy"
    this.setActiveButton(this.policyBtnTarget)
    this.toggleCalendarEventFields(false)
    this.setCriticalMassCopy("Critical Mass", "How many signatories are required for this policy to take effect?", "signatories required")
    this.setDeadlineCopy("Deadline", "When must critical mass be reached?")
    this.setSubmitLabel("Publish Policy")
  }

  private setActiveButton(active: HTMLButtonElement): void {
    this.actionBtnTarget.className = "pulse-action-btn-secondary"
    this.calendarEventBtnTarget.className = "pulse-action-btn-secondary"
    this.policyBtnTarget.className = "pulse-action-btn-secondary"
    active.className = "pulse-action-btn"
  }

  private toggleCalendarEventFields(show: boolean): void {
    if (!this.hasCalendarEventFieldsTarget) return
    this.calendarEventFieldsTarget.style.display = show ? "" : "none"
  }

  private setCriticalMassCopy(title: string, description: string, suffix: string): void {
    if (this.hasCriticalMassTitleTarget) this.criticalMassTitleTarget.textContent = title
    if (this.hasCriticalMassDescriptionTarget) this.criticalMassDescriptionTarget.textContent = description
    if (this.hasCriticalMassSuffixTarget) this.criticalMassSuffixTarget.textContent = suffix
  }

  private setDeadlineCopy(title: string, description: string): void {
    if (this.hasDeadlineTitleTarget) this.deadlineTitleTarget.textContent = title
    if (this.hasDeadlineDescriptionTarget) this.deadlineDescriptionTarget.textContent = description
  }

  private setSubmitLabel(label: string): void {
    if (!this.hasSubmitButtonTarget) return
    this.submitButtonTarget.value = label
  }
}
