import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import MarkdownPreviewController from "./markdown_preview_controller"

describe("MarkdownPreviewController", () => {
  let application: Application

  beforeEach(() => {
    document.head.innerHTML = `<meta name="csrf-token" content="test-csrf-token">`

    document.body.innerHTML = `
      <div class="pulse-md-editor"
           data-controller="markdown-preview"
           data-markdown-preview-url-value="/markdown/preview"
           data-markdown-preview-inline-value="false">
        <div class="pulse-md-tabs">
          <button type="button" class="pulse-md-tab is-active"
                  data-markdown-preview-target="writeTab"
                  data-action="markdown-preview#showWrite">Write</button>
          <button type="button" class="pulse-md-tab"
                  data-markdown-preview-target="previewTab"
                  data-action="markdown-preview#showPreview">Preview</button>
        </div>
        <textarea data-markdown-preview-target="input"></textarea>
        <div class="markdown-body pulse-md-preview" data-markdown-preview-target="preview" hidden></div>
      </div>
    `

    application = Application.start()
    application.register("markdown-preview", MarkdownPreviewController)
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  const els = () => ({
    write: document.querySelector("[data-markdown-preview-target='writeTab']") as HTMLElement,
    preview: document.querySelector("[data-markdown-preview-target='previewTab']") as HTMLElement,
    textarea: document.querySelector("textarea") as HTMLTextAreaElement,
    pane: document.querySelector("[data-markdown-preview-target='preview']") as HTMLElement,
  })

  it("starts in write mode with the textarea visible", async () => {
    await vi.waitFor(() => {
      const { textarea, pane } = els()
      expect(textarea.hidden).toBe(false)
      expect(pane.hidden).toBe(true)
    })
  })

  it("fetches and shows rendered HTML when Preview is clicked", async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve("<p><strong>bold</strong></p>"),
    })
    vi.stubGlobal("fetch", mockFetch)

    const { write, preview, textarea, pane } = els()
    textarea.value = "**bold**"
    preview.click()

    await vi.waitFor(() => {
      expect(pane.innerHTML).toContain("<strong>bold</strong>")
    })

    // textarea hidden, preview shown, tabs reflect active state
    expect(textarea.hidden).toBe(true)
    expect(pane.hidden).toBe(false)
    expect(preview.classList.contains("is-active")).toBe(true)
    expect(write.classList.contains("is-active")).toBe(false)

    // POSTed the text with the CSRF token
    expect(mockFetch.mock.calls[0][0]).toContain("/markdown/preview")
    expect(mockFetch.mock.calls[0][1].method).toBe("POST")
    expect(mockFetch.mock.calls[0][1].headers["X-CSRF-Token"]).toBe("test-csrf-token")
    expect(mockFetch.mock.calls[0][1].body).toContain("text=%2A%2Abold%2A%2A")
  })

  it("does not fetch when the textarea is empty", async () => {
    const mockFetch = vi.fn()
    vi.stubGlobal("fetch", mockFetch)

    const { preview, pane } = els()
    preview.click()

    await vi.waitFor(() => {
      expect(pane.innerHTML).toContain("Nothing to preview")
    })
    expect(mockFetch).not.toHaveBeenCalled()
  })

  it("returns to write mode and restores the textarea", async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve("<p>hi</p>"),
    })
    vi.stubGlobal("fetch", mockFetch)

    const { write, preview, textarea, pane } = els()
    textarea.value = "hi"
    preview.click()
    await vi.waitFor(() => expect(pane.hidden).toBe(false))

    write.click()
    expect(textarea.hidden).toBe(false)
    expect(pane.hidden).toBe(true)
    expect(write.classList.contains("is-active")).toBe(true)
    expect(preview.classList.contains("is-active")).toBe(false)
  })

  it("shows an error message when the request fails", async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: false })
    vi.stubGlobal("fetch", mockFetch)

    const { preview, textarea, pane } = els()
    textarea.value = "**bold**"
    preview.click()

    await vi.waitFor(() => {
      expect(pane.innerHTML).toContain("Couldn't load preview")
    })
  })

  it("sends inline=true when configured", async () => {
    const editor = document.querySelector(".pulse-md-editor") as HTMLElement
    editor.setAttribute("data-markdown-preview-inline-value", "true")

    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve("<strong>x</strong>"),
    })
    vi.stubGlobal("fetch", mockFetch)

    // Re-query after attribute change; controller value updates in place.
    const { preview, textarea } = els()
    textarea.value = "**x**"
    preview.click()

    await vi.waitFor(() => expect(mockFetch).toHaveBeenCalled())
    expect(mockFetch.mock.calls[0][1].body).toContain("inline=true")
  })
})
