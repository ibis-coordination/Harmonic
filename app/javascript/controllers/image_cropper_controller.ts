import { Controller } from "@hotwired/stimulus"
import Cropper from "cropperjs"

export default class ImageCropperController extends Controller {
  static targets = ["container", "image", "input", "modal", "cropperImage", "cropButton", "cancelButton", "croppedData", "form"]

  declare readonly containerTarget: HTMLElement
  declare readonly imageTarget: HTMLImageElement
  declare readonly inputTarget: HTMLInputElement
  declare readonly modalTarget: HTMLElement
  declare readonly cropperImageTarget: HTMLImageElement
  declare readonly cropButtonTarget: HTMLButtonElement
  declare readonly cancelButtonTarget: HTMLButtonElement
  declare readonly croppedDataTarget: HTMLInputElement
  declare readonly formTarget: HTMLFormElement

  private cropper: Cropper | null = null
  private boundKeyHandler: ((e: KeyboardEvent) => void) | null = null

  connect(): void {
    this.boundKeyHandler = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeyHandler)
  }

  disconnect(): void {
    if (this.boundKeyHandler) {
      document.removeEventListener("keydown", this.boundKeyHandler)
    }
    if (this.cropper) {
      this.cropper.destroy()
      this.cropper = null
    }
  }

  openFilePicker(): void {
    this.inputTarget.click()
  }

  handleFileSelect(event: Event): void {
    const target = event.target as HTMLInputElement
    const files = target.files
    if (files && files.length > 0) {
      const reader = new FileReader()
      reader.onload = (e: ProgressEvent<FileReader>) => {
        if (e.target?.result) {
          this.cropperImageTarget.src = e.target.result as string
          this.modalTarget.style.display = "block"
          this.cropper = new Cropper(this.cropperImageTarget, {
            aspectRatio: 1,
            viewMode: 1,
          })
        }
      }
      reader.readAsDataURL(files[0])
    }
  }

  crop(): void {
    if (!this.cropper) return
    const canvas = this.cropper.getCroppedCanvas()
    canvas.toBlob((blob) => {
      if (!blob) return
      const reader = new FileReader()
      reader.onloadend = () => {
        this.croppedDataTarget.value = reader.result as string
        this.formTarget.submit()
        this.closeModal()
      }
      reader.readAsDataURL(blob)
    })
  }

  cancel(): void {
    this.closeModal()
  }

  closeOnOverlay(event: Event): void {
    if (event.target === this.modalTarget) {
      this.closeModal()
    }
  }

  private closeModal(): void {
    if (this.cropper) {
      this.cropper.destroy()
      this.cropper = null
    }
    this.modalTarget.style.display = "none"
    this.cropperImageTarget.src = ""
    this.inputTarget.value = ""
  }

  private handleKeydown(e: KeyboardEvent): void {
    if (e.key === "Escape" && this.modalTarget.style.display === "block") {
      this.closeModal()
    }
  }
}
