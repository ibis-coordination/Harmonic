import { Controller } from "@hotwired/stimulus"
import { ianaToRailsTimezone, parseDatetimeInTimezone } from "../utils/timezone_mapping"

export default class DatetimeInputController extends Controller {
  static targets = ["datetimeInput", "timezoneSelect", "error", "countdown"]
  static values = {
    defaultOffset: { type: String, default: "7d" },
    requireFuture: { type: Boolean, default: true },
    utcValue: { type: String, default: "" },
  }

  declare datetimeInputTarget: HTMLInputElement
  declare timezoneSelectTarget: HTMLSelectElement
  declare errorTarget: HTMLElement
  declare hasTimezoneSelectTarget: boolean
  declare hasErrorTarget: boolean
  declare countdownTarget: HTMLElement
  declare hasCountdownTarget: boolean

  declare defaultOffsetValue: string
  declare requireFutureValue: boolean
  declare utcValueValue: string

  connect() {
    this.autodetectTimezone()
    this.convertUtcToLocal()
    this.prefillDefault()
    this.setMinAttribute()
    this.updateCountdown()
  }

  validate() {
    const value = this.datetimeInputTarget.value
    if (!value) {
      this.clearError()
      this.hideCountdown()
      return
    }

    const selected = this.selectedDateAsUtc()
    const isFuture = selected.getTime() > Date.now()

    if (this.requireFutureValue && !isFuture) {
      this.showError("Must be in the future")
      this.hideCountdown()
    } else {
      this.clearError()
      this.updateCountdown()
    }
  }

  // --- Private ---

  private autodetectTimezone() {
    if (!this.hasTimezoneSelectTarget) return

    try {
      const iana = Intl.DateTimeFormat().resolvedOptions().timeZone
      const railsName = ianaToRailsTimezone(iana)
      if (!railsName) return

      // Check if this option exists in the select
      const options = Array.from(this.timezoneSelectTarget.options)
      const match = options.find((opt) => opt.value === railsName)
      if (match) {
        this.timezoneSelectTarget.value = railsName
      }
    } catch {
      // Intl API not available — leave at server default
    }
  }

  private convertUtcToLocal() {
    if (!this.utcValueValue) return

    const utcDate = new Date(this.utcValueValue)
    if (isNaN(utcDate.getTime())) return

    this.datetimeInputTarget.value = this.formatDatetimeLocal(utcDate)
  }

  private prefillDefault() {
    if (this.datetimeInputTarget.value) return
    if (!this.defaultOffsetValue) return

    const offsetMs = this.parseOffset(this.defaultOffsetValue)
    if (offsetMs === null) return

    const future = new Date(Date.now() + offsetMs)
    this.datetimeInputTarget.value = this.formatDatetimeLocal(future)
  }

  private setMinAttribute() {
    this.datetimeInputTarget.min = this.formatDatetimeLocal(new Date())
  }

  private parseOffset(offset: string): number | null {
    const match = offset.match(/^(\d+)([smhdw])$/i)
    if (!match) return null

    const amount = parseInt(match[1], 10)
    const unit = match[2].toLowerCase()

    const multipliers: Record<string, number> = {
      s: 1_000,
      m: 60_000,
      h: 3_600_000,
      d: 86_400_000,
      w: 604_800_000,
    }

    return amount * (multipliers[unit] ?? 0)
  }

  private formatDatetimeLocal(date: Date): string {
    const pad = (n: number) => n.toString().padStart(2, "0")
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
  }

  private selectedDateAsUtc(): Date {
    const value = this.datetimeInputTarget.value
    if (!value) return new Date(NaN)
    if (!this.hasTimezoneSelectTarget) return new Date(value)
    return parseDatetimeInTimezone(value, this.timezoneSelectTarget.value)
  }

  private updateCountdown() {
    if (!this.hasCountdownTarget) return

    const value = this.datetimeInputTarget.value
    if (!value) {
      this.hideCountdown()
      return
    }

    const selected = this.selectedDateAsUtc()
    if (selected.getTime() <= Date.now()) {
      this.hideCountdown()
      return
    }

    this.countdownTarget.setAttribute("data-countdown-end-time-value", selected.toISOString())
    this.countdownTarget.style.display = ""
  }

  private hideCountdown() {
    if (!this.hasCountdownTarget) return
    this.countdownTarget.setAttribute("data-countdown-end-time-value", "")
    this.countdownTarget.style.display = "none"
  }

  private showError(message: string) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.style.display = ""
  }

  private clearError() {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = ""
    this.errorTarget.style.display = "none"
  }
}
