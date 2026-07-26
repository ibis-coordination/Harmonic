import { Controller } from "@hotwired/stimulus"

// Appends `--harness <slug>` to the setup-sprite command shown on the
// bridge-setup page as the operator picks one.
//
// The rendered command is the harness-neutral base, which is also a valid
// choice — selecting "None" restores it.
export default class HarnessSelectorController extends Controller {
  static targets = ["command"]

  declare readonly commandTarget: HTMLElement

  private baseCommand = ""

  connect(): void {
    this.baseCommand = this.commandTarget.textContent?.trim() ?? ""
  }

  select(event: Event): void {
    const slug = (event.target as HTMLInputElement).value
    const command = slug ? `${this.baseCommand} --harness ${slug}` : this.baseCommand

    this.commandTarget.textContent = command
    // The copy button reads its own hidden input rather than the displayed
    // text, so it has to be updated too or it hands over a stale command.
    const clipboardSource = this.element.querySelector<HTMLInputElement>('input[data-clipboard-target="source"]')
    if (clipboardSource) clipboardSource.value = command
  }
}
