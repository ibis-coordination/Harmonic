import { describe, it, expect, vi } from "vitest"
import { verifyChain, verifyVoteTallies, verifyBeacon, verifyAll, computeEntryHash } from "./audit_chain_verifier"
import type { VerifyData, AuditEntry } from "./audit_chain_types"

// Helper to build a minimal valid entry
function makeEntry(overrides: Partial<AuditEntry> & { sequence_number: number; action: string; entry_hash: string }): AuditEntry {
  return {
    actor_id: "",
    actor_handle: "",
    option_title: "",
    accepted: "",
    preferred: "",
    metadata: "",
    previous_hash: "",
    created_at: "2026-05-05T12:00:00Z",
    ...overrides,
  }
}

// Build a valid 2-entry chain using actual hash computation
async function buildValidChain(): Promise<{ entries: AuditEntry[]; lastHash: string }> {
  const entry1Partial = makeEntry({
    sequence_number: 1,
    action: "option_added",
    actor_id: "user-1",
    actor_handle: "alice",
    option_title: "Option A",
    previous_hash: "",
    entry_hash: "", // placeholder
  })
  const hash1 = await computeEntryHash(entry1Partial)
  entry1Partial.entry_hash = hash1

  const entry2Partial = makeEntry({
    sequence_number: 2,
    action: "vote_cast",
    actor_id: "user-1",
    actor_handle: "alice",
    option_title: "Option A",
    accepted: "1",
    preferred: "0",
    previous_hash: hash1,
    entry_hash: "", // placeholder
    created_at: "2026-05-05T12:01:00Z",
  })
  const hash2 = await computeEntryHash(entry2Partial)
  entry2Partial.entry_hash = hash2

  return { entries: [entry1Partial, entry2Partial], lastHash: hash2 }
}

describe("verifyChain", () => {
  it("passes for a valid chain", async () => {
    const { entries, lastHash } = await buildValidChain()
    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: lastHash,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: entries,
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(true)
    expect(result.entryCount).toBe(2)
    expect(result.errors).toEqual([])
    expect(result.lastHash).toBe(lastHash)
  })

  it("detects tampered entry_hash", async () => {
    const { entries } = await buildValidChain()
    entries[0].entry_hash = "tampered"

    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: null,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: entries,
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("hash mismatch"))).toBe(true)
  })

  it("detects broken chain link", async () => {
    const { entries } = await buildValidChain()
    entries[1].previous_hash = "wrong"

    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: null,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: entries,
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("chain link broken"))).toBe(true)
  })

  it("detects final chain hash mismatch", async () => {
    const { entries } = await buildValidChain()

    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: "wrong_hash",
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: entries,
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("chain hash mismatch"))).toBe(true)
  })

  it("passes for empty chain", async () => {
    const data: VerifyData = {
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

    const result = await verifyChain(data)
    expect(result.valid).toBe(true)
    expect(result.entryCount).toBe(0)
  })
})

describe("verifyVoteTallies", () => {
  it("passes when replayed votes match results", () => {
    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: null,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: [
        makeEntry({ sequence_number: 1, action: "vote_cast", actor_id: "u1", option_title: "A", accepted: "1", preferred: "1", entry_hash: "h1" }),
        makeEntry({ sequence_number: 2, action: "vote_cast", actor_id: "u2", option_title: "A", accepted: "0", preferred: "0", entry_hash: "h2" }),
        makeEntry({ sequence_number: 3, action: "vote_cast", actor_id: "u1", option_title: "B", accepted: "1", preferred: "0", entry_hash: "h3" }),
      ],
      results: [
        { position: 1, option_title: "A", accepted_yes: 1, preferred: 1, lottery_sort_key: null },
        { position: 2, option_title: "B", accepted_yes: 1, preferred: 0, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(true)
    expect(result.errors).toEqual([])
  })

  it("detects acceptance count mismatch", () => {
    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: null,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: [
        makeEntry({ sequence_number: 1, action: "vote_cast", actor_id: "u1", option_title: "A", accepted: "1", preferred: "0", entry_hash: "h1" }),
      ],
      results: [
        { position: 1, option_title: "A", accepted_yes: 5, preferred: 0, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("acceptance count"))).toBe(true)
  })

  it("detects preference count mismatch", () => {
    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: null,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: [
        makeEntry({ sequence_number: 1, action: "vote_cast", actor_id: "u1", option_title: "A", accepted: "1", preferred: "1", entry_hash: "h1" }),
      ],
      results: [
        { position: 1, option_title: "A", accepted_yes: 1, preferred: 99, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("preference count"))).toBe(true)
  })

  it("handles vote_updated correctly", () => {
    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "vote",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: null,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: [
        makeEntry({ sequence_number: 1, action: "vote_cast", actor_id: "u1", option_title: "A", accepted: "0", preferred: "0", entry_hash: "h1" }),
        makeEntry({ sequence_number: 2, action: "vote_updated", actor_id: "u1", option_title: "A", accepted: "1", preferred: "1", entry_hash: "h2" }),
      ],
      results: [
        { position: 1, option_title: "A", accepted_yes: 1, preferred: 1, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(true)
  })

  it("passes with no votes", () => {
    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "lottery",
        deadline: "2026-05-06T12:00:00Z",
        audit_chain_hash: null,
        lottery_beacon_round: null,
        lottery_beacon_randomness: null,
      },
      audit_chain: [],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(true)
  })
})

describe("verifyBeacon", () => {
  // drand quicknet params
  const GENESIS_TIME = 1692803367
  const PERIOD = 3

  it("passes when round and sort keys match", async () => {
    const deadlineUnix = GENESIS_TIME + 1000 * PERIOD
    const expectedRound = Math.floor((deadlineUnix - GENESIS_TIME) / PERIOD) + 2
    const deadline = new Date(deadlineUnix * 1000).toISOString()
    const randomness = "abcdef1234567890"

    // Compute expected sort key
    const encoder = new TextEncoder()
    const sortKeyBytes = await crypto.subtle.digest("SHA-256", encoder.encode(randomness + "Option A"))
    const sortKey = Array.from(new Uint8Array(sortKeyBytes)).map((b) => b.toString(16).padStart(2, "0")).join("")

    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "lottery",
        deadline,
        audit_chain_hash: null,
        lottery_beacon_round: expectedRound,
        lottery_beacon_randomness: randomness,
      },
      audit_chain: [],
      beacon: { round: expectedRound, randomness, verification_url: "" },
      results: [
        { position: 1, option_title: "Option A", accepted_yes: 0, preferred: 0, lottery_sort_key: sortKey },
      ],
    }

    const fetchRandomness = vi.fn().mockResolvedValue(randomness)
    const result = await verifyBeacon(data, fetchRandomness)
    expect(result.valid).toBe(true)
    expect(result.errors).toEqual([])
    expect(fetchRandomness).toHaveBeenCalledWith(expectedRound)
  })

  it("detects round mismatch", async () => {
    const deadlineUnix = GENESIS_TIME + 1000 * PERIOD
    const deadline = new Date(deadlineUnix * 1000).toISOString()

    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "lottery",
        deadline,
        audit_chain_hash: null,
        lottery_beacon_round: 999,
        lottery_beacon_randomness: "abc",
      },
      audit_chain: [],
      beacon: { round: 999, randomness: "abc", verification_url: "" },
    }

    const fetchRandomness = vi.fn().mockResolvedValue("abc")
    const result = await verifyBeacon(data, fetchRandomness)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("round"))).toBe(true)
  })

  it("detects randomness mismatch", async () => {
    const deadlineUnix = GENESIS_TIME + 1000 * PERIOD
    const expectedRound = Math.floor((deadlineUnix - GENESIS_TIME) / PERIOD) + 2
    const deadline = new Date(deadlineUnix * 1000).toISOString()

    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "lottery",
        deadline,
        audit_chain_hash: null,
        lottery_beacon_round: expectedRound,
        lottery_beacon_randomness: "server_says_this",
      },
      audit_chain: [],
      beacon: { round: expectedRound, randomness: "server_says_this", verification_url: "" },
    }

    const fetchRandomness = vi.fn().mockResolvedValue("drand_says_that")
    const result = await verifyBeacon(data, fetchRandomness)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("randomness"))).toBe(true)
  })

  it("returns skipped when drand fetch fails", async () => {
    const deadlineUnix = GENESIS_TIME + 1000 * PERIOD
    const expectedRound = Math.floor((deadlineUnix - GENESIS_TIME) / PERIOD) + 2
    const deadline = new Date(deadlineUnix * 1000).toISOString()

    const data: VerifyData = {
      decision: {
        id: "d1",
        question: "Test?",
        subtype: "lottery",
        deadline,
        audit_chain_hash: null,
        lottery_beacon_round: expectedRound,
        lottery_beacon_randomness: "abc",
      },
      audit_chain: [],
      beacon: { round: expectedRound, randomness: "abc", verification_url: "" },
    }

    const fetchRandomness = vi.fn().mockRejectedValue(new Error("network error"))
    const result = await verifyBeacon(data, fetchRandomness)
    expect(result.valid).toBe(true)
    expect(result.skipped).toBe(true)
    expect(result.errors.length).toBeGreaterThan(0)
  })

  it("skips when no beacon present", async () => {
    const data: VerifyData = {
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

    const result = await verifyBeacon(data)
    expect(result.valid).toBe(true)
    expect(result.skipped).toBe(true)
    expect(result.errors.some((e) => e.includes("No beacon drawn yet"))).toBe(true)
  })
})

describe("cross-implementation hash consistency", () => {
  // Reference hash computed by Ruby: Digest::SHA256.hexdigest("v1||1|vote_cast|user-123|alice|Option A|1|0||2026-05-05T12:00:00Z")
  const REFERENCE_HASH = "69cafa9533d7a4201cc21d45470c78e2589f20d1cfe0ff35cc4ce2c0fa44be35"

  it("computes the same hash as Ruby and Python for a known input", async () => {
    const entry = makeEntry({
      sequence_number: 1,
      action: "vote_cast",
      actor_id: "user-123",
      actor_handle: "alice",
      option_title: "Option A",
      accepted: "1",
      preferred: "0",
      metadata: "",
      previous_hash: "",
      entry_hash: "",
      created_at: "2026-05-05T12:00:00Z",
    })
    const hash = await computeEntryHash(entry)
    expect(hash).toBe(REFERENCE_HASH)
  })

  it("handles Unicode NFC normalization consistently", async () => {
    // "é" can be encoded as U+00E9 (precomposed) or U+0065 U+0301 (decomposed)
    // NFC normalization should produce the same hash for both
    const entryNFC = makeEntry({
      sequence_number: 1,
      action: "option_added",
      option_title: "\u00E9", // precomposed é
      entry_hash: "",
    })
    const entryNFD = makeEntry({
      sequence_number: 1,
      action: "option_added",
      option_title: "\u0065\u0301", // decomposed é
      entry_hash: "",
    })
    const hashNFC = await computeEntryHash(entryNFC)
    const hashNFD = await computeEntryHash(entryNFD)
    expect(hashNFC).toBe(hashNFD)
  })
})

describe("verifyAll", () => {
  it("returns combined results", async () => {
    const data: VerifyData = {
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

    const result = await verifyAll(data)
    expect(result.valid).toBe(true)
    expect(result.chain.valid).toBe(true)
    expect(result.voteTallies.valid).toBe(true)
    expect(result.beacon.valid).toBe(true)
  })
})
