import { Controller } from "@hotwired/stimulus"

// Live-disable a submit button for a finite number of seconds, with a visible
// countdown that re-enables the button when it hits zero. Used on /activate's
// resend-confirmation-email action so users see why the button is dimmed and
// don't have to refresh the page to try again.
//
// Markup (server-rendered): the countdown target wraps the whole message
// (shown/hidden on enable); the countdownNumber target is the number digits
// only, so the surrounding text stays put while the number ticks down. Give
// .pulse-activation-cooldown-num a fixed inline-block width in CSS so 2- to
// 1-digit transitions don't shift the "s" suffix.
//
//   <div data-controller="cooldown-button" data-cooldown-button-seconds-value="30">
//     <form action="..." method="post">
//       <button type="submit" disabled>Resend confirmation email</button>
//     </form>
//     <p data-cooldown-button-target="countdown">
//       Available in <span data-cooldown-button-target="countdownNumber"
//                          class="pulse-activation-cooldown-num">30</span>s
//     </p>
//   </div>
export default class extends Controller {
  static targets = ["countdown", "countdownNumber"]
  static values = { seconds: Number }

  declare readonly countdownTarget: HTMLElement
  declare readonly hasCountdownTarget: boolean
  declare readonly countdownNumberTarget: HTMLElement
  declare readonly hasCountdownNumberTarget: boolean
  declare secondsValue: number

  private interval: ReturnType<typeof setInterval> | null = null

  connect(): void {
    if (this.secondsValue <= 0) {
      // Rendered with a zero/missing value (no cooldown active) or the
      // server-side check raced past zero before render. Make sure the button
      // is enabled and exit — no need to schedule a tick.
      this.enableButtonAndHideCountdown()
      return
    }
    this.interval = setInterval(() => this.tick(), 1000)
  }

  disconnect(): void {
    if (this.interval) clearInterval(this.interval)
  }

  private tick(): void {
    this.secondsValue -= 1
    if (this.secondsValue <= 0) {
      this.enableButtonAndHideCountdown()
      this.clearInterval()
      return
    }
    if (this.hasCountdownNumberTarget) {
      this.countdownNumberTarget.textContent = String(this.secondsValue)
    }
  }

  private enableButtonAndHideCountdown(): void {
    const button = this.element.querySelector("button")
    if (button) button.disabled = false
    if (this.hasCountdownTarget) {
      this.countdownTarget.style.display = "none"
    }
  }

  private clearInterval(): void {
    if (this.interval) {
      clearInterval(this.interval)
      this.interval = null
    }
  }
}
