import { Controller } from "@hotwired/stimulus"
import { DirectUpload, DirectUploadBlob } from "@rails/activestorage"

// Drag/drop + paste + file-picker uploader for note images. Two modes:
//
//   Edit mode (note exists): each picked file direct-uploads to
//   ActiveStorage, then POSTs to <note path>/media_items with the
//   signed_id to materialize a MediaItem. Removal and alt-text edits
//   call the same endpoint by id.
//
//   Pending mode (new note, not saved yet): direct-upload still runs,
//   but instead of POSTing to a media_items endpoint we append hidden
//   inputs to the surrounding <form> named media_items[<i>][signed_id]
//   (+ [alt_text] when set). The note controller reads these on submit
//   and creates MediaItem rows after the note is persisted.
//
// Wiring requirements on the host element:
//   data-controller="note-media-uploader"
//   data-note-media-uploader-pending-value="<bool>"
//   data-note-media-uploader-create-url-value="<note path>/media_items"   (edit mode only)
//
// Targets: dropzone, fileInput, preview (container for tiles)
export default class NoteMediaUploaderController extends Controller<HTMLElement> {
  static targets = ["dropzone", "fileInput", "preview"]
  static values = {
    directUploadUrl: { type: String, default: "/rails/active_storage/direct_uploads" },
    createUrl: String,
    pending: { type: Boolean, default: false },
    maxBytes: { type: Number, default: 0 },
  }

  declare readonly dropzoneTarget: HTMLElement
  declare readonly fileInputTarget: HTMLInputElement
  declare readonly previewTarget: HTMLElement
  declare readonly directUploadUrlValue: string
  declare readonly createUrlValue: string
  declare readonly pendingValue: boolean
  declare readonly maxBytesValue: number

  private pendingIndex = 0

  private boundPaste = (event: ClipboardEvent) => this.handlePaste(event)

  connect() {
    document.addEventListener("paste", this.boundPaste)
  }

  disconnect() {
    document.removeEventListener("paste", this.boundPaste)
  }

  // --- Trigger sources -------------------------------------------------

  openPicker(event: Event) {
    event.preventDefault()
    this.fileInputTarget.click()
  }

  onFileInputChange() {
    this.handleFiles(Array.from(this.fileInputTarget.files || []))
    this.fileInputTarget.value = ""
  }

  onDragOver(event: DragEvent) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("is-dragover")
  }

  onDragLeave() {
    this.dropzoneTarget.classList.remove("is-dragover")
  }

  onDrop(event: DragEvent) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("is-dragover")
    const files = Array.from(event.dataTransfer?.files || [])
    this.handleFiles(files)
  }

  private handlePaste(event: ClipboardEvent) {
    if (!this.element.contains(document.activeElement) && document.activeElement !== document.body) return

    const items = event.clipboardData?.items
    if (!items) return
    const files: File[] = []
    for (const item of items) {
      if (item.kind === "file") {
        const f = item.getAsFile()
        if (f && f.type.startsWith("image/")) files.push(f)
      }
    }
    if (files.length > 0) {
      event.preventDefault()
      this.handleFiles(files)
    }
  }

  // --- Upload pipeline -------------------------------------------------

  private handleFiles(files: File[]) {
    for (const file of files) {
      if (!file.type.startsWith("image/")) continue

      // Reject files that would be rejected server-side anyway; saves the
      // user a full upload + 4xx round-trip. The server is still the source
      // of truth — DirectUploadsController enforces the byte_size cap
      // whether the client checks or not.
      if (this.maxBytesValue > 0 && file.size > this.maxBytesValue) {
        this.showRejectedTile(file, `Too large (${formatBytes(file.size)} > ${formatBytes(this.maxBytesValue)})`)
        continue
      }

      this.uploadOne(file)
    }
  }

  private showRejectedTile(file: File, reason: string) {
    const tile = this.createTile(file)
    this.markError(tile, reason)
  }

  private uploadOne(file: File) {
    const tile = this.createTile(file)
    const upload = new DirectUpload(file, this.directUploadUrlValue, {
      directUploadWillStoreFileWithXHR: (xhr) => {
        xhr.upload.addEventListener("progress", (event) => {
          if (event.lengthComputable) {
            const pct = Math.round((event.loaded / event.total) * 100)
            this.setProgress(tile, pct)
          }
        })
      },
    })

    upload.create((error, blob) => {
      if (error) {
        this.markError(tile, error.message || "Upload failed")
        return
      }
      if (this.pendingValue) {
        this.stashPendingBlob(tile, blob)
      } else {
        this.attachAsMediaItem(tile, blob)
      }
    })
  }

  // Pending mode: the note doesn't exist yet, so we can't materialize a
  // MediaItem. Instead, attach hidden inputs to the surrounding <form>
  // so the controller can create MediaItem rows after it saves the note.
  private stashPendingBlob(tile: HTMLElement, blob: DirectUploadBlob) {
    const form = this.element.closest("form")
    if (!form) {
      this.markError(tile, "No surrounding form for pending upload")
      return
    }

    const index = this.pendingIndex++
    tile.dataset.pendingIndex = String(index)

    const signedInput = document.createElement("input")
    signedInput.type = "hidden"
    signedInput.name = `media_items[${index}][signed_id]`
    signedInput.value = blob.signed_id
    signedInput.dataset.pendingFieldFor = String(index)
    form.appendChild(signedInput)

    this.finalizePendingTile(tile, form, index)
  }

  private finalizePendingTile(tile: HTMLElement, form: HTMLFormElement, index: number) {
    tile.dataset.state = "uploaded"
    const overlay = tile.querySelector<HTMLElement>("[data-role='progress']")
    overlay?.remove()

    const altInput = document.createElement("input")
    altInput.type = "text"
    altInput.className = "alt-input"
    altInput.placeholder = "Describe this image (alt text)"
    altInput.addEventListener("change", () => {
      this.updatePendingAlt(form, index, altInput.value)
    })
    tile.appendChild(altInput)
  }

  private updatePendingAlt(form: HTMLFormElement, index: number, value: string) {
    let altInput = form.querySelector<HTMLInputElement>(
      `input[name='media_items[${index}][alt_text]']`,
    )
    if (!altInput) {
      altInput = document.createElement("input")
      altInput.type = "hidden"
      altInput.name = `media_items[${index}][alt_text]`
      altInput.dataset.pendingFieldFor = String(index)
      form.appendChild(altInput)
    }
    altInput.value = value
  }

  private removePendingFields(form: HTMLFormElement, index: string) {
    form.querySelectorAll(`input[data-pending-field-for='${index}']`).forEach((el) => el.remove())
  }

  private attachAsMediaItem(tile: HTMLElement, blob: DirectUploadBlob) {
    const formData = new FormData()
    formData.append("signed_id", blob.signed_id)

    fetch(this.createUrlValue, {
      method: "POST",
      headers: {
        "X-CSRF-Token": getCsrfToken(),
        Accept: "application/json",
      },
      credentials: "same-origin",
      body: formData,
    })
      .then(async (response) => {
        if (!response.ok) {
          const body = await response.json().catch(() => ({}))
          const msg = Array.isArray(body.errors) ? body.errors.join(", ") : (body.error || "Attach failed")
          throw new Error(msg)
        }
        return response.json()
      })
      .then((item) => {
        this.finalizeTile(tile, item)
      })
      .catch((error) => {
        this.markError(tile, error.message)
      })
  }

  // --- Tile rendering --------------------------------------------------

  private createTile(file: File): HTMLElement {
    const tile = document.createElement("div")
    tile.className = "note-media-uploader-item"
    tile.dataset.state = "uploading"

    const img = document.createElement("img")
    img.alt = ""
    const reader = new FileReader()
    reader.onload = (event) => {
      img.src = String(event.target?.result || "")
    }
    reader.readAsDataURL(file)
    tile.appendChild(img)

    const overlay = document.createElement("div")
    overlay.className = "progress-overlay"
    overlay.dataset.role = "progress"
    overlay.textContent = "0%"
    tile.appendChild(overlay)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "remove-btn"
    remove.setAttribute("aria-label", "Remove image")
    remove.textContent = "×"
    remove.addEventListener("click", () => this.handleRemove(tile))
    tile.appendChild(remove)

    this.previewTarget.appendChild(tile)
    return tile
  }

  private setProgress(tile: HTMLElement, pct: number) {
    const overlay = tile.querySelector<HTMLElement>("[data-role='progress']")
    if (overlay) overlay.textContent = `${pct}%`
  }

  private finalizeTile(tile: HTMLElement, item: { id: string; alt_text?: string | null }) {
    tile.dataset.state = "uploaded"
    tile.dataset.mediaItemId = item.id
    const overlay = tile.querySelector<HTMLElement>("[data-role='progress']")
    overlay?.remove()

    const altInput = document.createElement("input")
    altInput.type = "text"
    altInput.className = "alt-input"
    altInput.placeholder = "Describe this image (alt text)"
    altInput.value = item.alt_text || ""
    altInput.addEventListener("change", () => this.handleAltChange(tile, altInput.value))
    tile.appendChild(altInput)
  }

  private markError(tile: HTMLElement, message: string) {
    tile.classList.add("has-error")
    const overlay = tile.querySelector<HTMLElement>("[data-role='progress']")
    if (overlay) overlay.textContent = message
  }

  private handleRemove(tile: HTMLElement) {
    const itemId = tile.dataset.mediaItemId
    const pendingIndex = tile.dataset.pendingIndex

    // Pending-mode tile: clean up the form-side hidden inputs and detach.
    // The blob persists in ActiveStorage as an orphan until purge runs;
    // that's acceptable — same outcome as navigating away without submit.
    if (pendingIndex !== undefined) {
      const form = this.element.closest("form")
      if (form) this.removePendingFields(form, pendingIndex)
      tile.remove()
      return
    }

    tile.remove()
    if (!itemId) return

    fetch(`${this.createUrlValue}/${itemId}`, {
      method: "DELETE",
      headers: {
        "X-CSRF-Token": getCsrfToken(),
        Accept: "application/json",
      },
      credentials: "same-origin",
    }).catch(() => {
      // Best-effort: tile is already gone from the UI. A subsequent
      // page load reveals any zombie that didn't actually delete.
    })
  }

  private handleAltChange(tile: HTMLElement, value: string) {
    const itemId = tile.dataset.mediaItemId
    if (!itemId) return

    const formData = new FormData()
    formData.append("alt_text", value)

    fetch(`${this.createUrlValue}/${itemId}`, {
      method: "PATCH",
      headers: {
        "X-CSRF-Token": getCsrfToken(),
        Accept: "application/json",
      },
      credentials: "same-origin",
      body: formData,
    }).catch(() => {
      // Silent — the user can re-edit if needed. Server is the source of truth.
    })
  }

  // Server-rendered tiles (already-uploaded media items on the edit page)
  // wire their remove button + alt input directly via data-action. These
  // public methods route to the same handlers as JS-created tiles.

  removeExisting(event: Event) {
    const tile = (event.currentTarget as HTMLElement).closest<HTMLElement>(".note-media-uploader-item")
    if (!tile) return
    this.handleRemove(tile)
  }

  updateExistingAlt(event: Event) {
    const input = event.currentTarget as HTMLInputElement
    const tile = input.closest<HTMLElement>(".note-media-uploader-item")
    if (!tile) return
    this.handleAltChange(tile, input.value)
  }
}

function getCsrfToken(): string {
  const meta = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
  return meta?.content || ""
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}
