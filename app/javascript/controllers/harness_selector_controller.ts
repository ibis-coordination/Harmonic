import { Controller } from "@hotwired/stimulus"

// Composes the setup-sprite command shown on the bridge-setup page from the
// operator's choices: `--harness <slug>` and, when the setup carries the LLM
// gateway opt-in, `--model <provider/model>` (those radios exist only then).
//
// The command is recomputed from the server-rendered base value plus the
// currently-checked radios — never derived from the displayed <pre>. Turbo
// caches the mutated page, so after a restore the <pre> already carries
// flags (and the radios keep their checked state); connect() recomputes so
// the two agree again instead of accumulating flags.
export default class HarnessSelectorController extends Controller {
  static targets = ["command"]
  static values = { base: String }

  declare readonly commandTarget: HTMLElement
  declare readonly baseValue: string

  connect(): void {
    this.render()
  }

  selectHarness(): void {
    this.render()
  }

  selectModel(): void {
    this.render()
  }

  private checked(name: string): string {
    const radio = this.element.querySelector<HTMLInputElement>(`input[name="${name}"]:checked`)
    return radio?.value ?? ""
  }

  private render(): void {
    const harness = this.checked("sprite_harness")
    const model = this.checked("sprite_model")
    const command =
      this.baseValue + (harness ? ` --harness ${harness}` : "") + (model ? ` --model ${model}` : "")

    this.commandTarget.textContent = command
    // The copy button reads its own hidden input rather than the displayed
    // text, so it has to be updated too or it hands over a stale command.
    const clipboardSource = this.element.querySelector<HTMLInputElement>('input[data-clipboard-target="source"]')
    if (clipboardSource) clipboardSource.value = command
  }
}
