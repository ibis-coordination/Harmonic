import { Controller } from "@hotwired/stimulus"

export default class RecoveryCodesController extends Controller {
  static targets = ["copyButton"]
  static values = {
    codes: Array,
  }

  declare readonly copyButtonTarget: HTMLButtonElement
  declare readonly codesValue: string[]

  private timeout: ReturnType<typeof setTimeout> | null = null

  copy(): void {
    const text = this.codesValue.join("\n")

    navigator.clipboard.writeText(text).then(() => {
      const originalText = this.copyButtonTarget.textContent
      this.copyButtonTarget.textContent = "Copied!"

      if (this.timeout) {
        clearTimeout(this.timeout)
      }

      this.timeout = setTimeout(() => {
        this.copyButtonTarget.textContent = originalText
      }, 2000)
    })
  }

  download(): void {
    const text =
      "Harmonic Recovery Codes\n" +
      "========================\n" +
      "Generated: " +
      new Date().toISOString() +
      "\n\n" +
      this.codesValue.join("\n") +
      "\n\n" +
      "Keep these codes safe. Each code can only be used once."

    const blob = new Blob([text], { type: "text/plain" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = "harmonic-recovery-codes.txt"
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  }
}
