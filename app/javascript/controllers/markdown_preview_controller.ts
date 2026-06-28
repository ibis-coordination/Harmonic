import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

/**
 * Adds a GitHub-style Write / Preview toggle to a markdown text field.
 *
 * The preview is rendered server-side (via the same MarkdownRenderer used to
 * display posted content), so what you see in the preview matches what gets
 * posted — including sanitization and reference linking.
 *
 * Expected markup:
 *   <div data-controller="markdown-preview"
 *        data-markdown-preview-url-value="/markdown/preview"
 *        data-markdown-preview-inline-value="false">
 *     <div class="markdown-preview-tabs">
 *       <button type="button" data-markdown-preview-target="writeTab"
 *               data-action="markdown-preview#showWrite">Write</button>
 *       <button type="button" data-markdown-preview-target="previewTab"
 *               data-action="markdown-preview#showPreview">Preview</button>
 *     </div>
 *     <textarea data-markdown-preview-target="input"></textarea>
 *     <div class="markdown-body markdown-preview-pane" data-markdown-preview-target="preview" hidden></div>
 *   </div>
 */
export default class MarkdownPreviewController extends Controller {
  static targets = ["input", "preview", "writeTab", "previewTab"]
  static values = {
    url: String,
    inline: { type: Boolean, default: false },
  }

  declare readonly inputTarget: HTMLTextAreaElement
  declare readonly previewTarget: HTMLElement
  declare readonly writeTabTarget: HTMLElement
  declare readonly previewTabTarget: HTMLElement
  declare readonly hasInputTarget: boolean
  declare readonly hasPreviewTarget: boolean
  declare readonly hasWriteTabTarget: boolean
  declare readonly hasPreviewTabTarget: boolean
  declare urlValue: string
  declare inlineValue: boolean

  connect(): void {
    this.showWrite()
  }

  showWrite(event?: Event): void {
    event?.preventDefault()
    if (this.hasInputTarget) this.inputTarget.hidden = false
    if (this.hasPreviewTarget) this.previewTarget.hidden = true
    this.setActiveTab(this.hasWriteTabTarget ? this.writeTabTarget : null)
  }

  async showPreview(event?: Event): Promise<void> {
    event?.preventDefault()
    if (!this.hasPreviewTarget || !this.hasInputTarget) return

    if (this.hasInputTarget) this.inputTarget.hidden = true
    this.previewTarget.hidden = false
    this.setActiveTab(this.hasPreviewTabTarget ? this.previewTabTarget : null)

    const text = this.inputTarget.value
    if (text.trim() === "") {
      this.previewTarget.innerHTML = `<p class="pulse-md-empty">Nothing to preview.</p>`
      return
    }

    this.previewTarget.innerHTML = `<p class="pulse-md-empty">Loading preview…</p>`

    try {
      const body = new URLSearchParams()
      body.set("text", text)
      if (this.inlineValue) body.set("inline", "true")

      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
          "Content-Type": "application/x-www-form-urlencoded",
          Accept: "text/html",
        },
        body: body.toString(),
      })

      if (response.ok) {
        this.previewTarget.innerHTML = await response.text()
      } else {
        this.previewTarget.innerHTML = `<p class="pulse-md-empty">Couldn't load preview.</p>`
      }
    } catch (error) {
      console.error("Error loading markdown preview:", error)
      this.previewTarget.innerHTML = `<p class="pulse-md-empty">Couldn't load preview.</p>`
    }
  }

  private setActiveTab(active: HTMLElement | null): void {
    const tabs: HTMLElement[] = []
    if (this.hasWriteTabTarget) tabs.push(this.writeTabTarget)
    if (this.hasPreviewTabTarget) tabs.push(this.previewTabTarget)
    for (const tab of tabs) {
      const isActive = tab === active
      tab.classList.toggle("is-active", isActive)
      tab.setAttribute("aria-selected", isActive ? "true" : "false")
    }
  }
}
