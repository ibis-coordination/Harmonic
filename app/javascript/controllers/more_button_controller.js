import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["button","menu","plus","plusMenu"]

  connect() {
    this.menuTarget.style.display = 'none'
    document.addEventListener('click', (event) => {
      const isClickInside = this.menuTarget.contains(event.target) || this.buttonTarget.contains(event.target) ||
                            this.plusMenuTarget.contains(event.target) || this.plusTarget.contains(event.target)
      const isClickOn = event.target === this.buttonTarget || event.target === this.menuTarget ||
                        event.target === this.plusTarget || event.target === this.plusMenuTarget
      const isMenuVisible = this.menuTarget.style.display === 'block' || this.plusMenuTarget.style.display === 'block'
      if (!isClickInside && !isClickOn && isMenuVisible) {
        this.menuTarget.style.display = 'none'
        this.plusMenuTarget.style.display = 'none'
      }
    })
  }

  toggleMenu() {
    // get the computed x and y position of the button and then set the menu position, right aligned with the button
    // and account for the scroll position
    const rect = this.buttonTarget.getBoundingClientRect()
    const scrollTop = window.scrollY || document.documentElement.scrollTop
    this.menuTarget.style.position = 'absolute'
    this.menuTarget.style.top = `${rect.bottom + scrollTop}px`
    this.menuTarget.style.right = `${window.innerWidth - rect.right}px`

    this.menuTarget.style.display = this.menuTarget.style.display === 'none' ? 'block' : 'none'
    this.plusMenuTarget.style.display = 'none'
  }

  togglePlusMenu() {
    // get the computed x and y position of the button and then set the menu position, right aligned with the button
    // and account for the scroll position
    const rect = this.plusTarget.getBoundingClientRect()
    const scrollTop = window.scrollY || document.documentElement.scrollTop
    this.plusMenuTarget.style.position = 'absolute'
    this.plusMenuTarget.style.top = `${rect.bottom + scrollTop}px`
    this.plusMenuTarget.style.right = `${window.innerWidth - rect.right}px`

    this.plusMenuTarget.style.display = this.plusMenuTarget.style.display === 'none' ? 'block' : 'none'
    this.menuTarget.style.display = 'none'
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']").content;
  }

  togglePin(event) {
    const originalText = event.target.textContent.trim()
    const url = event.target.dataset.url
    const isPinned = originalText.split(' ')[0] === 'Unpin'
    event.target.textContent = isPinned ? "Unpinning..." : "Pinning..."
    fetch(url, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify({
        pinned: !isPinned,
      }),
    }).then(response => {
      if (response.ok) return response.json()
      throw new Error("Network response was not ok.")
    }).then(responseBody => {
      event.target.textContent = responseBody.pinned ? "Pinned!" : "Unpinned!"
      setTimeout(() => {
        event.target.textContent = (responseBody.pinned ? "Unpin from " : "Pin to ") + originalText.split(' ').slice(2).join(' ')
      }, 2000)
    })
  }

  pin(event) {
    this.togglePin(event)
  }
}