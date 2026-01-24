// depends on image_cropper.css
import Cropper from "cropperjs"

document.addEventListener("DOMContentLoaded", function () {
  // Support both new container-based UI and legacy image-only UI
  const profileImageContainer = document.getElementById("profile-image-container")
  const profileImage = document.getElementById("profile-image")
  const profileImageInput = document.getElementById("profile-image-input") as HTMLInputElement | null
  const cropperModal = document.getElementById("cropper-modal")
  const cropperImage = document.getElementById("cropper-image") as HTMLImageElement | null
  const cropButton = document.getElementById("crop-button")
  const cropperCancel = document.getElementById("cropper-cancel")
  const croppedImageData = document.getElementById("cropped-image-data") as HTMLInputElement | null
  const form = document.getElementById("profile-image-form") as HTMLFormElement | null
  let cropper: Cropper | null = null

  // Only initialize if required elements exist (this script runs on pages without the cropper)
  if (!profileImageInput || !cropperModal || !cropperImage || !cropButton || !croppedImageData || !form) {
    return
  }

  // Click handler - prefer container, fall back to image
  const clickTarget = profileImageContainer || profileImage
  if (clickTarget) {
    clickTarget.addEventListener("click", function () {
      profileImageInput.click()
    })
  }

  profileImageInput.addEventListener("change", function (event: Event) {
    const target = event.target as HTMLInputElement
    const files = target.files
    if (files && files.length > 0) {
      const reader = new FileReader()
      reader.onload = function (e: ProgressEvent<FileReader>) {
        if (e.target?.result) {
          cropperImage.src = e.target.result as string
          cropperModal.style.display = "block"
          cropper = new Cropper(cropperImage, {
            aspectRatio: 1,
            viewMode: 1,
          })
        }
      }
      reader.readAsDataURL(files[0])
    }
  })

  function closeModal(): void {
    if (cropper) {
      cropper.destroy()
      cropper = null
    }
    // These are guaranteed non-null by the early return check above
    cropperModal!.style.display = "none"
    cropperImage!.src = ""
    // Reset the file input so the same file can be selected again
    profileImageInput!.value = ""
  }

  cropButton.addEventListener("click", function () {
    if (!cropper) return
    const canvas = cropper.getCroppedCanvas()
    canvas.toBlob(function (blob) {
      if (!blob) return
      const reader = new FileReader()
      reader.onloadend = function () {
        croppedImageData.value = reader.result as string
        form.submit()
      }
      reader.readAsDataURL(blob)
    })
    closeModal()
  })

  // Cancel button handler
  if (cropperCancel) {
    cropperCancel.addEventListener("click", closeModal)
  }

  // Close on overlay click (outside modal content)
  cropperModal.addEventListener("click", function (e: Event) {
    if (e.target === cropperModal) {
      closeModal()
    }
  })

  // Close on Escape key
  document.addEventListener("keydown", function (e: KeyboardEvent) {
    if (e.key === "Escape" && cropperModal.style.display === "block") {
      closeModal()
    }
  })
})
