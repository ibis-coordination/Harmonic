import { Controller } from "@hotwired/stimulus"

export default class LogoutController extends Controller {
  async logout(event: Event): Promise<void> {
    event.preventDefault()

    const csrfMeta = document.querySelector('meta[name="csrf-token"]') as HTMLMetaElement | null
    if (!csrfMeta) {
      console.error("CSRF token not found")
      return
    }

    const response = await fetch("/logout", {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfMeta.content,
      },
      credentials: "same-origin",
    })

    if (response.ok) {
      window.location.href = "/"
    } else {
      console.error("Logout failed:", response.statusText)
    }
  }
}
