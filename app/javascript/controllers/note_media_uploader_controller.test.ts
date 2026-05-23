import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"

// Mock @rails/activestorage's DirectUpload so we don't actually hit
// /rails/active_storage/direct_uploads or the underlying storage service.
// Each instance gives us a handle to the callback so we can drive the
// success / error paths deterministically.
const directUploadCreateCalls: Array<{
  file: File
  url: string
  callback: (
    error: Error | null,
    blob: { signed_id: string; id: number; key: string; filename: string; content_type: string; byte_size: number; checksum: string },
  ) => void
}> = []

vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    file: File
    url: string
    constructor(file: File, url: string, _delegate?: unknown) {
      this.file = file
      this.url = url
    }
    create(
      cb: (
        error: Error | null,
        blob: { signed_id: string; id: number; key: string; filename: string; content_type: string; byte_size: number; checksum: string },
      ) => void,
    ) {
      directUploadCreateCalls.push({ file: this.file, url: this.url, callback: cb })
    }
  },
}))

// Imported AFTER the mock so the mock is in place at controller-load time.
// eslint-disable-next-line @typescript-eslint/no-require-imports
import NoteMediaUploaderController from "./note_media_uploader_controller"

describe("NoteMediaUploaderController", () => {
  let application: Application
  let fetchMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    directUploadCreateCalls.length = 0
    application = Application.start()
    application.register("note-media-uploader", NoteMediaUploaderController)

    // Stub global fetch so the create/update/destroy endpoints don't
    // actually fire HTTP requests. Tests can override the resolved value
    // by reassigning fetchMock.mockImplementation.
    fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ id: "mediaitem-123", alt_text: "" }), {
        status: 201,
        headers: { "Content-Type": "application/json" },
      }),
    )
    vi.stubGlobal("fetch", fetchMock)

    // CSRF meta tag so getCsrfToken() returns something.
    const meta = document.createElement("meta")
    meta.name = "csrf-token"
    meta.content = "test-csrf-token"
    document.head.appendChild(meta)
  })

  afterEach(() => {
    application.stop()
    vi.unstubAllGlobals()
    document.head.querySelectorAll('meta[name="csrf-token"]').forEach((el) => el.remove())
    document.body.innerHTML = ""
  })

  async function renderEditMode() {
    document.body.innerHTML = `
      <form id="parent-form">
        <section
          data-controller="note-media-uploader"
          data-note-media-uploader-pending-value="false"
          data-note-media-uploader-max-bytes-value="15728640"
          data-note-media-uploader-create-url-value="/n/abc/media_items"
        >
          <input type="file" hidden data-note-media-uploader-target="fileInput"
                 data-action="change->note-media-uploader#onFileInputChange">
          <div data-note-media-uploader-target="dropzone"
               data-action="drop->note-media-uploader#onDrop"></div>
          <div data-note-media-uploader-target="preview"></div>
        </section>
      </form>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  async function renderPendingMode() {
    document.body.innerHTML = `
      <form id="parent-form">
        <section
          data-controller="note-media-uploader"
          data-note-media-uploader-pending-value="true"
          data-note-media-uploader-max-bytes-value="15728640"
        >
          <input type="file" hidden data-note-media-uploader-target="fileInput"
                 data-action="change->note-media-uploader#onFileInputChange">
          <div data-note-media-uploader-target="dropzone"
               data-action="drop->note-media-uploader#onDrop"></div>
          <div data-note-media-uploader-target="preview"></div>
        </section>
      </form>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  function makeFile(opts: { name?: string; type?: string; size?: number } = {}): File {
    const f = new File([new Uint8Array(opts.size || 1024)], opts.name || "a.png", {
      type: opts.type ?? "image/png",
    })
    return f
  }

  function dropFiles(files: File[]) {
    const dropzone = document.querySelector<HTMLElement>(
      "[data-note-media-uploader-target='dropzone']",
    )!
    // jsdom doesn't implement DataTransfer; construct a plain Event and
    // attach a `files`-bearing object. The controller only reads
    // event.dataTransfer.files, so this minimal shim is enough.
    const event = new Event("drop", { bubbles: true, cancelable: true }) as DragEvent
    Object.defineProperty(event, "dataTransfer", {
      value: { files },
      writable: false,
    })
    dropzone.dispatchEvent(event)
  }

  // -------- Edit mode --------------------------------------------------

  it("edit mode: dropping a file creates a tile and triggers DirectUpload", async () => {
    await renderEditMode()
    dropFiles([makeFile()])

    expect(directUploadCreateCalls.length).toBe(1)
    const tile = document.querySelector(".note-media-uploader-item")
    expect(tile).not.toBeNull()
    expect(tile!.getAttribute("data-state")).toBe("uploading")
  })

  it("edit mode: on successful DirectUpload, POSTs signed_id to createUrl", async () => {
    await renderEditMode()
    dropFiles([makeFile()])

    // Resolve the upload.
    const { callback } = directUploadCreateCalls[0]
    callback(null, fakeBlob("signed-123"))
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledOnce()
    const [url, opts] = fetchMock.mock.calls[0]
    expect(url).toBe("/n/abc/media_items")
    expect(opts.method).toBe("POST")
    expect(opts.headers["X-CSRF-Token"]).toBe("test-csrf-token")
    const body = opts.body as FormData
    expect(body.get("signed_id")).toBe("signed-123")
  })

  it("edit mode: after server confirms, tile is marked uploaded with media_item id", async () => {
    await renderEditMode()
    dropFiles([makeFile()])

    const { callback } = directUploadCreateCalls[0]
    callback(null, fakeBlob("signed-456"))
    await flushPromises()

    const tile = document.querySelector<HTMLElement>(".note-media-uploader-item")!
    expect(tile.dataset.state).toBe("uploaded")
    expect(tile.dataset.mediaItemId).toBe("mediaitem-123")
  })

  it("edit mode: DirectUpload error marks the tile as errored", async () => {
    await renderEditMode()
    dropFiles([makeFile()])

    const { callback } = directUploadCreateCalls[0]
    callback(new Error("boom"), fakeBlob("never"))
    await flushPromises()

    const tile = document.querySelector<HTMLElement>(".note-media-uploader-item")!
    expect(tile.classList.contains("has-error")).toBe(true)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("edit mode: server error response marks the tile as errored", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ errors: ["invalid signed_id"] }), {
        status: 422,
        headers: { "Content-Type": "application/json" },
      }),
    )
    await renderEditMode()
    dropFiles([makeFile()])

    const { callback } = directUploadCreateCalls[0]
    callback(null, fakeBlob("signed-x"))
    await flushPromises()

    const tile = document.querySelector<HTMLElement>(".note-media-uploader-item")!
    expect(tile.classList.contains("has-error")).toBe(true)
  })

  // -------- File filtering --------------------------------------------

  it("rejects oversized files client-side without calling DirectUpload", async () => {
    await renderEditMode()
    const tooBig = makeFile({ size: 20 * 1024 * 1024 }) // 20MB > 15MB cap
    dropFiles([tooBig])

    expect(directUploadCreateCalls.length).toBe(0)
    const tile = document.querySelector<HTMLElement>(".note-media-uploader-item")!
    expect(tile.classList.contains("has-error")).toBe(true)
  })

  it("ignores files whose mime type is not image/*", async () => {
    await renderEditMode()
    const notImage = new File(["x"], "doc.pdf", { type: "application/pdf" })
    dropFiles([notImage])

    expect(directUploadCreateCalls.length).toBe(0)
    expect(document.querySelector(".note-media-uploader-item")).toBeNull()
  })

  // -------- Pending mode ----------------------------------------------

  it("pending mode: success path adds hidden inputs to the surrounding form", async () => {
    await renderPendingMode()
    dropFiles([makeFile()])

    const { callback } = directUploadCreateCalls[0]
    callback(null, fakeBlob("signed-pending"))
    await flushPromises()

    const form = document.querySelector<HTMLFormElement>("#parent-form")!
    const signed = form.querySelector<HTMLInputElement>(
      "input[name='media_items[0][signed_id]']",
    )
    expect(signed).not.toBeNull()
    expect(signed!.value).toBe("signed-pending")

    // Should NOT have POSTed to a server endpoint in pending mode.
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("pending mode: editing the alt input appends an alt_text hidden input", async () => {
    await renderPendingMode()
    dropFiles([makeFile()])

    const { callback } = directUploadCreateCalls[0]
    callback(null, fakeBlob("signed-pending"))
    await flushPromises()

    const altInput = document.querySelector<HTMLInputElement>(
      ".note-media-uploader-item .alt-input",
    )!
    altInput.value = "A photo"
    altInput.dispatchEvent(new Event("change", { bubbles: true }))

    const form = document.querySelector<HTMLFormElement>("#parent-form")!
    const alt = form.querySelector<HTMLInputElement>(
      "input[name='media_items[0][alt_text]']",
    )
    expect(alt).not.toBeNull()
    expect(alt!.value).toBe("A photo")
  })

  it("pending mode: removing a tile cleans up its hidden inputs", async () => {
    await renderPendingMode()
    dropFiles([makeFile()])

    const { callback } = directUploadCreateCalls[0]
    callback(null, fakeBlob("signed-pending"))
    await flushPromises()

    const form = document.querySelector<HTMLFormElement>("#parent-form")!
    expect(
      form.querySelector("input[name='media_items[0][signed_id]']"),
    ).not.toBeNull()

    const removeBtn = document.querySelector<HTMLButtonElement>(
      ".note-media-uploader-item .remove-btn",
    )!
    removeBtn.click()

    expect(form.querySelector("input[name='media_items[0][signed_id]']")).toBeNull()
    expect(document.querySelector(".note-media-uploader-item")).toBeNull()
  })

  it("pending mode: multiple drops yield uniquely-indexed hidden inputs", async () => {
    await renderPendingMode()
    dropFiles([makeFile({ name: "1.png" }), makeFile({ name: "2.png" })])

    expect(directUploadCreateCalls.length).toBe(2)
    directUploadCreateCalls.forEach((c, i) => c.callback(null, fakeBlob(`signed-${i}`)))
    await flushPromises()

    const form = document.querySelector<HTMLFormElement>("#parent-form")!
    expect(form.querySelector("input[name='media_items[0][signed_id]']")).not.toBeNull()
    expect(form.querySelector("input[name='media_items[1][signed_id]']")).not.toBeNull()
  })
})

// ----- Helpers --------------------------------------------------------

function fakeBlob(signedId: string) {
  return {
    signed_id: signedId,
    id: 1,
    key: "k",
    filename: "a.png",
    content_type: "image/png",
    byte_size: 100,
    checksum: "abc",
  }
}

async function flushPromises() {
  // Two ticks: one for the fetch promise to resolve, one for its chained
  // .then. Sufficient for our test handlers; bump if more are added.
  await new Promise((r) => setTimeout(r, 0))
  await new Promise((r) => setTimeout(r, 0))
}
