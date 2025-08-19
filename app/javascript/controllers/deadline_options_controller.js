import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = []

  connect() {
    this.element.addEventListener('click', this.selectOption.bind(this))
  }

  selectOption(event) {
    let optionContainer = event.target.parentElement
    if (!optionContainer.classList.contains('deadline-option')) {
      optionContainer = optionContainer.parentElement
    }
    optionContainer.children[0].checked = true
  }

}