import { Controller } from "@hotwired/stimulus"

export default class NavController extends Controller {
  static targets = ["icon"]

  declare readonly iconTarget: HTMLElement
  declare readonly hasIconTarget: boolean

  log(_event: Event): void {
    // console.log(event)
  }
}
