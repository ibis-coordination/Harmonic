import { Controller } from "@hotwired/stimulus"

// How long push cleanup may delay logout before we give up and submit anyway.
const CLEANUP_TIMEOUT_MS = 1500

/**
 * LogoutController releases this device's push subscription on explicit
 * logout: it unsubscribes browser-side and reports the endpoint in the
 * form's hidden push_endpoint field so the server can revoke the matching
 * WebPushSubscription row. Push deliberately survives session timeouts —
 * only explicit logout ends device trust.
 *
 * Attached to the logout form (button_to):
 *
 *   <form data-controller="logout" data-action="submit->logout#prepare">
 *     <input type="hidden" name="push_endpoint" value="">
 *     ...
 *
 * Cleanup is strictly best-effort: any failure or delay must never block
 * logging out.
 */
export default class LogoutController extends Controller<HTMLFormElement> {
  private prepared = false

  async prepare(event: Event): Promise<void> {
    if (this.prepared) return
    if (!("serviceWorker" in navigator)) return

    event.preventDefault()
    this.prepared = true
    try {
      await withTimeout(this.releasePushSubscription(), CLEANUP_TIMEOUT_MS)
    } catch {
      // Best-effort: log out regardless.
    }
    this.element.requestSubmit()
  }

  private async releasePushSubscription(): Promise<void> {
    const registration = await navigator.serviceWorker.getRegistration()
    const subscription = await registration?.pushManager.getSubscription()
    if (!subscription) return

    // Fill the field before unsubscribing so the server still revokes its
    // row even if the browser-side unsubscribe fails.
    const field = this.element.querySelector<HTMLInputElement>('input[name="push_endpoint"]')
    if (field) field.value = subscription.endpoint
    await subscription.unsubscribe()
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T | void> {
  return Promise.race([promise, new Promise<void>((resolve) => setTimeout(resolve, ms))])
}
