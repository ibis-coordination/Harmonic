import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

/**
 * WebhookTestController sends a test delivery via fetch and renders the
 * response in a result block — no page reload, no scroll-to-top.
 *
 * Markup shape (rendered by app/views/notification_webhooks/show.html.erb):
 *
 *   <div data-controller="webhook-test"
 *        data-webhook-test-url-value="/u/dan/webhook/test">
 *     <button data-action="webhook-test#send">Send test delivery</button>
 *     <div data-webhook-test-target="result"></div>
 *   </div>
 *
 * The server responds with JSON:
 *   { ok: boolean,
 *     result: { status?, error?, body?, request_body_preview? } }
 */
export default class WebhookTestController extends Controller<HTMLElement> {
  static values = { url: String }
  static targets = ["result", "button"]

  declare urlValue: string
  declare resultTarget: HTMLElement
  declare buttonTarget: HTMLButtonElement
  declare hasButtonTarget: boolean

  async send(event: Event): Promise<void> {
    event.preventDefault()

    const button = this.hasButtonTarget ? this.buttonTarget : (event.currentTarget as HTMLButtonElement)
    const previousLabel = button.innerText
    button.disabled = true
    button.innerText = "Sending…"
    this.resultTarget.innerHTML = ""

    try {
      const response = await fetchWithCsrf(this.urlValue, {
        method: "POST",
        headers: { Accept: "application/json" },
      })
      const data = await response.json()
      this.resultTarget.innerHTML = this.renderResult(data)
    } catch (err) {
      this.resultTarget.innerHTML = this.renderError(err instanceof Error ? err.message : String(err))
    } finally {
      button.disabled = false
      button.innerText = previousLabel
    }
  }

  private renderResult(data: { ok: boolean; result: TestResult }): string {
    const { ok, result } = data
    const cls = ok ? "pulse-notice" : "pulse-notice pulse-notice-warning"
    let headline: string
    if (result.error) {
      headline = `<strong>Test delivery error:</strong> ${escapeHtml(result.error)}`
    } else if (ok) {
      headline = `<strong>Test delivery succeeded</strong> (HTTP ${escapeHtml(String(result.status))}).`
    } else {
      headline = `<strong>Test delivery returned HTTP ${escapeHtml(String(result.status))}.</strong> Check your server.`
    }

    const bodyBlock = result.body
      ? `<details style="margin-top:8px;">
           <summary>Response body</summary>
           <pre style="white-space:pre-wrap;background:var(--bg-tertiary);padding:8px;border-radius:4px;font-size:12px;">${escapeHtml(result.body)}</pre>
         </details>`
      : ""
    const requestBlock = result.request_body_preview
      ? `<details style="margin-top:8px;">
           <summary>What Harmonic sent</summary>
           <pre style="white-space:pre-wrap;background:var(--bg-tertiary);padding:8px;border-radius:4px;font-size:12px;">${escapeHtml(result.request_body_preview)}</pre>
         </details>`
      : ""

    return `<div class="${cls}" style="margin-top:16px;">${headline}${bodyBlock}${requestBlock}</div>`
  }

  private renderError(message: string): string {
    return `<div class="pulse-notice pulse-notice-warning" style="margin-top:16px;">
      <strong>Test delivery failed:</strong> ${escapeHtml(message)}
    </div>`
  }
}

interface TestResult {
  status?: number | string
  error?: string
  body?: string
  request_body_preview?: string
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}
