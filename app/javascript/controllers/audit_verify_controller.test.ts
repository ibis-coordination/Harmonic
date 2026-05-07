import { describe, it, expect, beforeEach, vi, type Mock } from "vitest"
import { Application } from "@hotwired/stimulus"
import AuditVerifyController from "./audit_verify_controller"
import { waitForController } from "../test/setup"
import { computeEntryHash } from "../lib/audit_chain_verifier"
import type { VerifyData, AuditEntry } from "../lib/audit_chain_types"

const validData: VerifyData = {
  decision: {
    id: "d1",
    question: "Test?",
    subtype: "vote",
    deadline: "2026-05-06T12:00:00Z",
    audit_chain_hash: null,
    lottery_beacon_round: null,
    lottery_beacon_randomness: null,
  },
  audit_chain: [],
}

function setupDOM(url: string): void {
  document.body.innerHTML = `
    <div data-controller="audit-verify"
         data-audit-verify-url-value="${url}">
      <div data-audit-verify-target="results">Verifying...</div>
    </div>
  `
}

function resultsText(): string {
  return document.querySelector("[data-audit-verify-target='results']")?.textContent ?? ""
}

function resultsHtml(): string {
  return document.querySelector("[data-audit-verify-target='results']")?.innerHTML ?? ""
}

describe("AuditVerifyController", () => {
  let fetchMock: Mock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal("fetch", fetchMock)
  })

  async function startController(): Promise<void> {
    const application = Application.start()
    application.register("audit-verify", AuditVerifyController)
    await waitForController()
    await new Promise((resolve) => setTimeout(resolve, 50))
  }

  // --- Happy path ---

  it("shows detailed pass results for valid empty chain", async () => {
    setupDOM("/verify.json")
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve(validData),
    })

    await startController()

    const text = resultsText()
    expect(text).toContain("PASS")
    expect(text).toContain("0 entries verified")
    expect(text).toContain("All checks passed")
  })

  it("uses verification-pass CSS class for passing checks", async () => {
    setupDOM("/verify.json")
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve(validData),
    })

    await startController()

    const html = resultsHtml()
    expect(html).toContain("verification-pass")
    expect(html).not.toContain("verification-fail")
  })

  // --- Fetch errors ---

  it("explains server error with guidance", async () => {
    setupDOM("/verify.json")
    fetchMock.mockImplementation(() =>
      Promise.resolve({
        ok: false,
        status: 500,
        json: () => Promise.reject(new Error("not ok")),
      }),
    )

    await startController()

    const text = resultsText()
    expect(text).toContain("Could not load audit data")
    expect(text).toContain("HTTP 500")
    expect(text).toContain("try refreshing")
    expect(text).toContain("verify independently")
  })

  it("explains network error with guidance", async () => {
    setupDOM("/verify.json")
    fetchMock.mockImplementation(() => Promise.reject(new Error("Network error")))

    await startController()

    const text = resultsText()
    expect(text).toContain("Network error")
    expect(text).toContain("internet connection")
    expect(text).toContain("verify independently")
  })

  // --- Chain integrity failures ---

  it("renders chain failure with integrity warning", async () => {
    // Build a chain with a tampered hash
    const entry: AuditEntry = {
      sequence_number: 1,
      action: "option_added",
      actor_id: "user-1",
      actor_handle: "alice",
      option_title: "Option A",
      accepted: "",
      preferred: "",
      metadata: "",
      previous_hash: "",
      entry_hash: "tampered_hash",
      created_at: "2026-05-05T12:00:00Z",
    }

    const tamperedData: VerifyData = {
      ...validData,
      audit_chain: [entry],
    }

    setupDOM("/verify.json")
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve(tamperedData),
    })

    await startController()

    const text = resultsText()
    expect(text).toContain("FAIL")
    expect(text).toContain("altered or corrupted")
    expect(text).toContain("serious integrity issue")
    expect(text).toContain("Do not rely")
    expect(text).toContain("hash mismatch")

    const html = resultsHtml()
    expect(html).toContain("verification-fail")
  })

  // --- Vote tally failures ---

  it("renders vote tally failure with tampering warning", async () => {
    const entry: AuditEntry = {
      sequence_number: 1,
      action: "vote_cast",
      actor_id: "user-1",
      actor_handle: "alice",
      option_title: "Option A",
      accepted: "1",
      preferred: "0",
      metadata: "",
      previous_hash: "",
      entry_hash: "",
      created_at: "2026-05-05T12:00:00Z",
    }
    entry.entry_hash = await computeEntryHash(entry)

    const mismatchData: VerifyData = {
      decision: { ...validData.decision, audit_chain_hash: entry.entry_hash },
      audit_chain: [entry],
      results: [
        { position: 1, option_title: "Option A", accepted_yes: 99, preferred: 0, lottery_sort_key: null },
      ],
    }

    setupDOM("/verify.json")
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve(mismatchData),
    })

    await startController()

    const text = resultsText()
    expect(text).toContain("Chain integrity:")
    expect(text).toMatch(/Chain integrity:.*PASS/)
    expect(text).toMatch(/Vote tallies:.*FAIL/)
    expect(text).toContain("do not match")
    expect(text).toContain("added, removed, or changed")
    expect(text).toContain("Do not rely")
  })

  // --- Beacon states ---

  it("renders beacon skip when drand is unreachable", async () => {
    const GENESIS_TIME = 1692803367
    const PERIOD = 3
    const deadlineUnix = GENESIS_TIME + 1000 * PERIOD
    const expectedRound = Math.floor((deadlineUnix - GENESIS_TIME) / PERIOD) + 2
    const deadline = new Date(deadlineUnix * 1000).toISOString()

    const beaconData: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "lottery",
        deadline,
        audit_chain_hash: null,
        lottery_beacon_round: expectedRound,
        lottery_beacon_randomness: "abc123",
      },
      audit_chain: [],
      beacon: { round: expectedRound, randomness: "abc123", verification_url: "" },
    }

    setupDOM("/verify.json")
    // First call: verify.json succeeds. Second call: drand fails.
    fetchMock.mockImplementation((url: string) => {
      if (url === "/verify.json") {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(beaconData) })
      }
      // drand fetch fails
      return Promise.reject(new Error("Failed to fetch"))
    })

    await startController()

    const text = resultsText()
    expect(text).toContain("SKIPPED")
    expect(text).toContain("drand randomness beacon")
    expect(text).toContain("temporarily unavailable")
    expect(text).toContain("Python script below")
    expect(text).toContain("Chain and vote checks passed")
  })

  it("renders beacon failure when randomness doesn't match drand", async () => {
    const GENESIS_TIME = 1692803367
    const PERIOD = 3
    const deadlineUnix = GENESIS_TIME + 1000 * PERIOD
    const expectedRound = Math.floor((deadlineUnix - GENESIS_TIME) / PERIOD) + 2
    const deadline = new Date(deadlineUnix * 1000).toISOString()

    const beaconData: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "lottery",
        deadline,
        audit_chain_hash: null,
        lottery_beacon_round: expectedRound,
        lottery_beacon_randomness: "server_claims_this",
      },
      audit_chain: [],
      beacon: { round: expectedRound, randomness: "server_claims_this", verification_url: "" },
      results: [
        { position: 1, option_title: "Option A", accepted_yes: 0, preferred: 0, lottery_sort_key: "abc" },
      ],
    }

    setupDOM("/verify.json")
    fetchMock.mockImplementation((url: string) => {
      if (url === "/verify.json") {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(beaconData) })
      }
      // drand returns different randomness
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve({ round: expectedRound, randomness: "drand_says_different" }),
      })
    })

    await startController()

    const text = resultsText()
    expect(text).toMatch(/Beacon verification:.*FAIL/)
    expect(text).toContain("random sorting could not be verified")
    expect(text).toContain("manipulated")
    expect(text).toContain("randomness does not match")
  })

  // --- Partial failures ---

  it("shows overall failure when any check fails", async () => {
    const entry: AuditEntry = {
      sequence_number: 1,
      action: "option_added",
      actor_id: "user-1",
      actor_handle: "alice",
      option_title: "Option A",
      accepted: "",
      preferred: "",
      metadata: "",
      previous_hash: "",
      entry_hash: "tampered",
      created_at: "2026-05-05T12:00:00Z",
    }

    const partialData: VerifyData = {
      ...validData,
      audit_chain: [entry],
    }

    setupDOM("/verify.json")
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve(partialData),
    })

    await startController()

    const text = resultsText()
    // Chain fails but vote tallies and beacon should still pass
    expect(text).toMatch(/Chain integrity:.*FAIL/)
    expect(text).toMatch(/Vote tallies:.*PASS/)
    expect(text).toMatch(/Beacon verification:.*PASS/)
    expect(text).toContain("One or more checks failed")
  })

  // --- HTML escaping ---

  it("escapes HTML in error messages to prevent XSS", async () => {
    const entry: AuditEntry = {
      sequence_number: 1,
      action: "vote_cast",
      actor_id: "user-1",
      actor_handle: "alice",
      option_title: '<img src=x onerror=alert(1)>',
      accepted: "1",
      preferred: "0",
      metadata: "",
      previous_hash: "",
      entry_hash: "",
      created_at: "2026-05-05T12:00:00Z",
    }
    entry.entry_hash = await computeEntryHash(entry)

    const xssData: VerifyData = {
      decision: { ...validData.decision, audit_chain_hash: entry.entry_hash },
      audit_chain: [entry],
      results: [
        { position: 1, option_title: '<img src=x onerror=alert(1)>', accepted_yes: 99, preferred: 0, lottery_sort_key: null },
      ],
    }

    setupDOM("/verify.json")
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve(xssData),
    })

    await startController()

    const html = resultsHtml()
    expect(html).not.toContain("<img")
    expect(html).toContain("&lt;img")
  })
})
