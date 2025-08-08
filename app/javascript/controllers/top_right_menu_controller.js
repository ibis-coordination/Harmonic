import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["button","menu"]

  connect() {
    this.menuTarget.style.display = 'none'
    document.addEventListener('click', (event) => {
      const isClickInside = this.menuTarget.contains(event.target) || this.buttonTarget.contains(event.target)
      const isClickOn = event.target === this.buttonTarget || event.target === this.menuTarget
      const isMenuVisible = this.menuTarget.style.display === 'block'
      if (!isClickInside && !isClickOn && isMenuVisible) {
        this.menuTarget.style.display = 'none'
        this.quickAppendInputTarget.value = ''
      }
    })
  }

  toggleMenu() {
    // get the computed x and y position of the button and then set the menu position, right aligned with the button
    const rect = this.buttonTarget.getBoundingClientRect()
    this.menuTarget.style.top = `${rect.bottom}px`
    this.menuTarget.style.right = `${window.innerWidth - rect.right}px`
    this.menuTarget.style.display = this.menuTarget.style.display === 'none' ? 'block' : 'none'
    // this.quickAppendInputTarget.focus()
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']").content;
  }

  // handleQuickAppendKeydown(event) {
  //   if (event.key === 'Enter' && this.quickAppendInputTarget.value.trim().length > 0) {
  //     const url = this.quickAppendInputTarget.dataset.url
  //     const value = this.quickAppendInputTarget.value
  //     this.quickAppendInputTarget.value = ''
  //     this.quickAppendInputTarget.placeholder = 'appending...'
  //     fetch(url, {
  //       method: "POST",
  //       headers: {
  //         "Content-Type": "application/json",
  //         "X-CSRF-Token": this.csrfToken,
  //       },
  //       body: JSON.stringify({ text: value }),
  //     }).then(response => {
  //       if (response.ok) {
  //         this.quickAppendInputTarget.placeholder = 'appended!'
  //         setTimeout(() => {
  //           this.quickAppendInputTarget.placeholder = 'quick append'
  //         }, 2000)
  //       } else {
  //         console.error("Error creating option:", response);
  //       }
  //     }).catch(error => {
  //       console.error("Error creating option:", error);
  //     })
  //   } else if (event.key === 'Escape') {
  //     this.menuTarget.style.display = 'none'
  //     this.quickAppendInputTarget.value = ''
  //   }
  // }
}