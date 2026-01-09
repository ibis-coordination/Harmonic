// depends on image_cropper.css
import Cropper from "cropperjs"

document.addEventListener("DOMContentLoaded", function () {
  const profileImage = document.getElementById("profile-image")
  const profileImageInput = document.getElementById("profile-image-input") as HTMLInputElement | null
  const cropperModal = document.getElementById("cropper-modal")
  const cropperImage = document.getElementById("cropper-image") as HTMLImageElement | null
  const cropButton = document.getElementById("crop-button")
  const croppedImageData = document.getElementById("cropped-image-data") as HTMLInputElement | null
  const form = document.getElementById("profile-image-form") as HTMLFormElement | null
  let cropper: Cropper | null = null

  // Only initialize if all elements exist (this script runs on pages without the cropper)
  if (!profileImage || !profileImageInput || !cropperModal || !cropperImage || !cropButton || !croppedImageData || !form) {
    return
  }

  profileImage.addEventListener("click", function () {
    profileImageInput.click()
  })

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
    cropperModal.style.display = "none"
  })
})
