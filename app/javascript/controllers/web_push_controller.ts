import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"
import { subscribeToPush } from "../pwa/subscribe"

/**
 * WebPushController wires the "Enable on this device" button on the user
 * settings page to the push subscription flow.
 *
 * Usage:
 *
 *   <div data-controller="web-push"
 *        data-web-push-url-value="/u/dan/settings/push-subscriptions">
 *     <button data-web-push-target="button"
 *             data-action="click->web-push#subscribe">Enable on this device</button>
 *     <p data-web-push-target="status" hidden></p>
 *   </div>
 *
 * The VAPID public key is read from the layout's meta tag. The button is
 * hidden when the browser doesn't support push (e.g. iOS Safari outside an
 * installed PWA).
 */
export default class WebPushController extends Controller<HTMLElement> {
  static values = { url: String }
  static targets = ["button", "status"]

  declare urlValue: string
  declare readonly buttonTarget: HTMLButtonElement
  declare readonly statusTarget: HTMLElement
  declare readonly hasButtonTarget: boolean
  declare readonly hasStatusTarget: boolean

  connect(): void {
    if (!this.supported && this.hasButtonTarget) {
      this.buttonTarget.hidden = true
      this.showStatus("Push isn't available in this browser. On iPhone or iPad, add Harmonic to your home screen first.")
    }
  }

  get supported(): boolean {
    return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
  }

  async subscribe(event: Event): Promise<void> {
    event.preventDefault()
    if (!this.supported) return

    const vapidPublicKey = (document.querySelector("meta[name='vapid-public-key']") as HTMLMetaElement | null)?.content
    if (!vapidPublicKey) {
      this.showStatus("Push isn't configured on this server.")
      return
    }

    this.buttonTarget.disabled = true
    const registration = await navigator.serviceWorker.ready

    const result = await subscribeToPush({
      vapidPublicKey,
      postUrl: this.urlValue,
      requestPermission: () => Notification.requestPermission(),
      getSubscription: () => registration.pushManager.getSubscription(),
      subscribe: (options) => registration.pushManager.subscribe(options),
      post: async (url, body) => {
        const response = await fetchWithCsrf(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        })
        return response.ok
      },
    })

    if (result === "subscribed") {
      // Reload so the device list and preference matrix reflect the new state.
      window.location.reload()
    } else {
      this.buttonTarget.disabled = false
      this.showStatus(
        result === "permission-denied"
          ? "Notifications are blocked for this site. Allow them in your browser settings, then try again."
          : "Something went wrong enabling push on this device. Try again.",
      )
    }
  }

  private showStatus(message: string): void {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.hidden = false
  }
}
