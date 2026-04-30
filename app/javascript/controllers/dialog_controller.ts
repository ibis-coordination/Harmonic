import { Controller } from "@hotwired/stimulus"

export default class DialogController extends Controller {
  static targets = ["dialog"]

  declare readonly dialogTarget: HTMLDialogElement

  open(): void {
    this.dialogTarget.showModal()
  }

  close(): void {
    this.dialogTarget.close()
  }
}
