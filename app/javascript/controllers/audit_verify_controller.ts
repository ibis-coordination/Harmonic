import { Controller } from "@hotwired/stimulus"
import { verifyAll } from "../lib/audit_chain_verifier"
import type { VerifyData, VerificationResult } from "../lib/audit_chain_types"

// drand quicknet chain parameters
const DRAND_CHAIN_HASH = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
const DRAND_BASE_URL = "https://api.drand.sh"

export default class AuditVerifyController extends Controller {
  static values = { url: String }
  static targets = ["results"]

  declare readonly urlValue: string
  declare readonly resultsTarget: HTMLElement

  async connect(): Promise<void> {
    await this.verify()
  }

  async verify(): Promise<void> {
    let data: VerifyData
    try {
      const response = await fetch(this.urlValue, { credentials: "same-origin" })
      if (!response.ok) {
        this.renderError(
          "Could not load audit data",
          `The server returned an error (HTTP ${response.status}) when fetching the audit chain data. ` +
          "This could be a temporary issue — try refreshing the page. " +
          "You can also verify independently using the Python script below.",
        )
        return
      }
      data = await response.json()
    } catch (error) {
      this.renderError(
        "Network error",
        "Could not connect to the server to fetch audit chain data. " +
        "Check your internet connection and try refreshing the page. " +
        "You can also verify independently using the Python script below.",
      )
      return
    }

    const fetchDrandRandomness = async (round: number): Promise<string> => {
      const url = `${DRAND_BASE_URL}/${DRAND_CHAIN_HASH}/public/${round}`
      const response = await fetch(url)
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const result = await response.json()
      return result.randomness
    }

    let result: VerificationResult
    try {
      result = await verifyAll(data, fetchDrandRandomness)
    } catch (error) {
      console.error("Audit verification error:", error)
      this.renderError(
        "Verification script error",
        "An unexpected error occurred while running the verification checks. " +
        "This is likely a bug in the verification code, not a problem with the decision data. " +
        `The error was: ${error instanceof Error ? error.message : String(error)}. ` +
        "You can verify independently using the Python script below to confirm whether the data is intact.",
      )
      return
    }

    this.renderResult(result, data.has_imported_entries === true)
  }

  private renderResult(result: VerificationResult, hasImportedEntries: boolean): void {
    const lines: string[] = []

    // Chain integrity (covers hash chain + identity binding for v2+ entries)
    if (result.chain.valid) {
      const scrubbed = result.chain.scrubbedCount
      const represented = result.chain.representedCount
      const detail = `All ${result.chain.entryCount} entries verified — every hash is correct and links to the previous entry.` +
        (represented > 0 ? ` ${represented} ${represented === 1 ? "action was" : "actions were"} performed on someone's behalf; both identities are recorded and verified.` : "") +
        (scrubbed > 0 ? ` ${scrubbed} ${scrubbed === 1 ? "entry has" : "entries have"} had identifying information removed (account closure); binding for ${scrubbed === 1 ? "that entry is" : "those entries are"} unattributable by design.` : "")
      lines.push(this.passLine("Chain integrity", detail))
    } else if (result.chain.errors.length > 0) {
      lines.push(this.failLine("Chain integrity", this.explainChainFailure(result.chain.errors, hasImportedEntries)))
    } else {
      // No hash/link errors — failure is from an identity binding mismatch
      // (actor or representative)
      lines.push(this.failLine("Chain integrity", this.explainBindingFailure(
        result.chain.bindingInconsistentCount + result.chain.representativeBindingInconsistentCount,
      )))
    }

    // Vote tallies
    if (result.voteTallies.skipped) {
      lines.push(this.warnLine("Vote tallies", result.voteTallies.errors[0] || "Vote tally verification was skipped."))
    } else if (result.voteTallies.valid) {
      lines.push(this.passLine("Vote tallies", "Replayed all votes from the audit chain — totals match the displayed results."))
    } else {
      lines.push(this.failLine("Vote tallies", this.explainTallyFailure(result.voteTallies.errors)))
    }

    // Beacon
    if (result.beacon.skipped) {
      lines.push(this.warnLine("Beacon verification", result.beacon.errors[0] || "Beacon verification was skipped."))
    } else if (result.beacon.valid) {
      lines.push(this.passLine("Beacon verification", "Randomness round and sort keys verified against the drand beacon."))
    } else {
      lines.push(this.failLine("Beacon verification", this.explainBeaconFailure(result.beacon.errors)))
    }

    // Overall
    const anySkipped = result.beacon.skipped || result.voteTallies.skipped
    if (result.valid && !anySkipped) {
      lines.push(`<p class="verification-pass" style="font-weight: 600; margin: 12px 0 0 0;">All checks passed.</p>`)
    } else if (result.valid && anySkipped) {
      lines.push(`<p style="font-weight: 600; margin: 12px 0 0 0;">Completed checks passed. Some checks were skipped — see above.</p>`)
    } else {
      lines.push(`<p class="verification-fail" style="font-weight: 600; margin: 12px 0 0 0;">One or more checks failed — see details above.</p>`)
    }

    this.resultsTarget.innerHTML = lines.join("\n")
  }

  private passLine(label: string, detail: string): string {
    return `<div style="margin-bottom: 8px;"><strong>${label}:</strong> <span class="verification-pass">PASS</span> — ${this.escapeHtml(detail)}</div>`
  }

  private failLine(label: string, detail: string): string {
    return `<div style="margin-bottom: 8px;"><strong>${label}:</strong> <span class="verification-fail">FAIL</span><div style="margin: 4px 0 0 8px; color: var(--color-danger-fg);">${this.escapeHtml(detail)}</div></div>`
  }

  private warnLine(label: string, detail: string): string {
    return `<div style="margin-bottom: 8px;"><strong>${label}:</strong> <span class="verification-error">SKIPPED</span><div style="margin: 4px 0 0 8px; color: var(--color-fg-muted);">${this.escapeHtml(detail)}</div></div>`
  }

  private explainChainFailure(errors: string[], hasImportedEntries: boolean): string {
    const parts = hasImportedEntries
      ? ["The recorded history of imported entries doesn't match what they originally hashed to. " +
         "This is expected: the import process adds a metadata flag to each entry to mark it as imported, " +
         "which changes the recorded hash. The differences below are the import-induced changes, " +
         "not tampering on this instance. See the imported-records notice at the top for context."]
      : ["The audit chain has been altered or corrupted. This is a serious integrity issue — " +
         "it means the recorded history of this decision may not be trustworthy. " +
         "Do not rely on the displayed results until this is investigated."]
    if (errors.length > 0) {
      parts.push("Details: " + errors.join("; ") + ".")
    }
    return parts.join(" ")
  }

  private explainTallyFailure(errors: string[]): string {
    const parts = ["The vote totals shown in the results do not match what the audit chain recorded. " +
      "This means votes may have been added, removed, or changed outside of the audited process. " +
      "Do not rely on the displayed results until this is investigated."]
    if (errors.length > 0) {
      parts.push("Details: " + errors.join("; ") + ".")
    }
    return parts.join(" ")
  }

  private explainBindingFailure(count: number): string {
    return `${count} ${count === 1 ? "entry's" : "entries'"} recorded identity (actor or representative) does not match its identity token. ` +
      "This means the displayed identity for those entries may have been altered after the fact, or that PII scrubbing was performed inconsistently. " +
      "The hash chain itself is intact, but you should not trust the displayed identity information until this is investigated."
  }

  private explainBeaconFailure(errors: string[]): string {
    const parts = ["The random sorting could not be verified against the drand randomness beacon. " +
      "This could mean the sort order was manipulated, or that the wrong beacon round was used."]
    if (errors.length > 0) {
      parts.push("Details: " + errors.join("; ") + ".")
    }
    return parts.join(" ")
  }

  private renderError(title: string, detail: string): void {
    this.resultsTarget.innerHTML = `<div style="margin-bottom: 8px;"><strong>${this.escapeHtml(title)}</strong><div style="margin: 4px 0 0 0; color: var(--color-fg-muted);">${this.escapeHtml(detail)}</div></div>`
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
