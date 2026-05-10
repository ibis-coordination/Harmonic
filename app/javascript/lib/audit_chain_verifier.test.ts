import { describe, it, expect, vi } from "vitest"
import { verifyChain, verifyVoteTallies, verifyBeacon, verifyAll, computeEntryHash, verifyActorBinding } from "./audit_chain_verifier"
import type { VerifyData, AuditEntry } from "./audit_chain_types"

const DECISION_ID = "d1"
const SALT = "deadbeef".repeat(8) // 64-hex placeholder

async function sha256hex(input: string): Promise<string> {
  const encoder = new TextEncoder()
  const buf = await crypto.subtle.digest("SHA-256", encoder.encode(input))
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

// Build an entry with a correctly-derived actor_token (when an actor is given)
// and a correctly-stamped entry_hash. Tests that want to forge tampering can
// mutate the returned entry after-the-fact.
async function makeEntry(opts: {
  decisionId?: string
  sequenceNumber: number
  action: string
  actorId?: string
  actorHandle?: string
  actorTokenSalt?: string
  optionTitle?: string
  accepted?: string
  preferred?: string
  metadata?: string
  previousHash?: string
  createdAt?: string
}): Promise<AuditEntry> {
  const decisionId = opts.decisionId ?? DECISION_ID
  const actorId = opts.actorId ?? ""
  const actorHandle = opts.actorHandle ?? ""
  const salt = opts.actorTokenSalt ?? (actorId ? SALT : "")
  const actorToken = actorId
    ? await sha256hex(`${decisionId}|${actorId}|${actorHandle}|${salt}`)
    : ""
  const entry: AuditEntry = {
    schema_version: 2,
    sequence_number: opts.sequenceNumber,
    action: opts.action,
    actor_id: actorId,
    actor_handle: actorHandle,
    actor_token: actorToken,
    actor_token_salt: salt,
    option_title: opts.optionTitle ?? "",
    accepted: opts.accepted ?? "",
    preferred: opts.preferred ?? "",
    metadata: opts.metadata ?? "",
    previous_hash: opts.previousHash ?? "",
    entry_hash: "",
    created_at: opts.createdAt ?? "2026-05-05T12:00:00Z",
  }
  entry.entry_hash = await computeEntryHash(entry)
  return entry
}

// Build a valid 2-entry chain with real hashes
async function buildValidChain(): Promise<{ entries: AuditEntry[]; lastHash: string }> {
  const e1 = await makeEntry({
    sequenceNumber: 1,
    action: "option_added",
    actorId: "user-1",
    actorHandle: "alice",
    optionTitle: "Option A",
  })
  const e2 = await makeEntry({
    sequenceNumber: 2,
    action: "vote_cast",
    actorId: "user-1",
    actorHandle: "alice",
    optionTitle: "Option A",
    accepted: "1",
    preferred: "0",
    previousHash: e1.entry_hash,
    createdAt: "2026-05-05T12:01:00Z",
  })
  return { entries: [e1, e2], lastHash: e2.entry_hash }
}

const baseDecision = {
  id: DECISION_ID,
  question: "Test?",
  subtype: "vote",
  deadline: "2026-05-06T12:00:00Z",
  audit_chain_hash: null as string | null,
  lottery_beacon_round: null as number | null,
  lottery_beacon_randomness: null as string | null,
}

describe("verifyChain", () => {
  it("passes for a valid chain", async () => {
    const { entries, lastHash } = await buildValidChain()
    const data: VerifyData = {
      decision: { ...baseDecision, audit_chain_hash: lastHash },
      audit_chain: entries,
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(true)
    expect(result.entryCount).toBe(2)
    expect(result.errors).toEqual([])
    expect(result.lastHash).toBe(lastHash)
    expect(result.bindingInconsistentCount).toBe(0)
    expect(result.scrubbedCount).toBe(0)
  })

  it("detects tampered entry_hash", async () => {
    const { entries } = await buildValidChain()
    entries[0].entry_hash = "tampered"

    const data: VerifyData = {
      decision: { ...baseDecision },
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
      decision: { ...baseDecision },
      audit_chain: entries,
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("chain link broken"))).toBe(true)
  })

  it("detects final chain hash mismatch", async () => {
    const { entries } = await buildValidChain()

    const data: VerifyData = {
      decision: { ...baseDecision, audit_chain_hash: "wrong_hash" },
      audit_chain: entries,
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("chain hash mismatch"))).toBe(true)
  })

  it("passes for empty chain", async () => {
    const data: VerifyData = {
      decision: { ...baseDecision },
      audit_chain: [],
    }

    const result = await verifyChain(data)
    expect(result.valid).toBe(true)
    expect(result.entryCount).toBe(0)
  })

  it("populates bindingStatuses for each entry", async () => {
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
      optionTitle: "Option A",
    })
    const data: VerifyData = {
      decision: { ...baseDecision, audit_chain_hash: entry.entry_hash },
      audit_chain: [entry],
    }
    const result = await verifyChain(data)
    expect(result.valid).toBe(true)
    expect(result.bindingStatuses[1]).toBe("verified")
    expect(result.bindingInconsistentCount).toBe(0)
    expect(result.scrubbedCount).toBe(0)
  })

  it("fails the chain when an actor identity has been swapped", async () => {
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
      optionTitle: "Option A",
    })
    // Tamper after entry_hash is stamped: swap actor_id but leave token intact.
    // Hash chain still verifies (token is in the hash, identity fields are not).
    entry.actor_id = "user-2"
    const data: VerifyData = {
      decision: { ...baseDecision, audit_chain_hash: entry.entry_hash },
      audit_chain: [entry],
    }
    const result = await verifyChain(data)
    expect(result.valid).toBe(false)
    expect(result.errors).toEqual([])
    expect(result.bindingInconsistentCount).toBe(1)
    expect(result.bindingStatuses[1]).toBe("tamper_or_scrub_inconsistent")
  })

  it("counts scrubbed entries without failing the chain", async () => {
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
      optionTitle: "Option A",
    })
    // Simulate post-scrub state: actor_id and salt are gone, token persists
    entry.actor_id = ""
    entry.actor_token_salt = ""
    const data: VerifyData = {
      decision: { ...baseDecision, audit_chain_hash: entry.entry_hash },
      audit_chain: [entry],
    }
    const result = await verifyChain(data)
    expect(result.valid).toBe(true)
    expect(result.scrubbedCount).toBe(1)
    expect(result.importedCount).toBe(0)
    expect(result.bindingInconsistentCount).toBe(0)
  })

  it("counts imported entries separately from scrubbed; chain stays valid", async () => {
    // Build with the imported flag baked into metadata so the hash matches
    // (we're testing verifier accounting in isolation; see the verifier test
    // above for the rationale).
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
      optionTitle: "Option A",
      metadata: JSON.stringify({ imported: true }),
    })
    entry.actor_token_salt = ""
    const data: VerifyData = {
      decision: { ...baseDecision, audit_chain_hash: entry.entry_hash },
      audit_chain: [entry],
    }
    const result = await verifyChain(data)
    expect(result.valid).toBe(true)
    expect(result.importedCount).toBe(1)
    expect(result.scrubbedCount).toBe(0)
    expect(result.bindingInconsistentCount).toBe(0)
  })
})

describe("verifyVoteTallies", () => {
  it("passes when replayed votes match results", async () => {
    const e1 = await makeEntry({ sequenceNumber: 1, action: "vote_cast", actorId: "u1", actorHandle: "a", optionTitle: "A", accepted: "1", preferred: "1" })
    const e2 = await makeEntry({ sequenceNumber: 2, action: "vote_cast", actorId: "u2", actorHandle: "b", optionTitle: "A", accepted: "0", preferred: "0", previousHash: e1.entry_hash })
    const e3 = await makeEntry({ sequenceNumber: 3, action: "vote_cast", actorId: "u1", actorHandle: "a", optionTitle: "B", accepted: "1", preferred: "0", previousHash: e2.entry_hash })

    const data: VerifyData = {
      decision: { ...baseDecision },
      audit_chain: [e1, e2, e3],
      results: [
        { position: 1, option_title: "A", accepted_yes: 1, preferred: 1, lottery_sort_key: null },
        { position: 2, option_title: "B", accepted_yes: 1, preferred: 0, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(true)
    expect(result.errors).toEqual([])
  })

  it("detects acceptance count mismatch", async () => {
    const entry = await makeEntry({ sequenceNumber: 1, action: "vote_cast", actorId: "u1", actorHandle: "a", optionTitle: "A", accepted: "1", preferred: "0" })
    const data: VerifyData = {
      decision: { ...baseDecision },
      audit_chain: [entry],
      results: [
        { position: 1, option_title: "A", accepted_yes: 5, preferred: 0, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("acceptance count"))).toBe(true)
  })

  it("detects preference count mismatch", async () => {
    const entry = await makeEntry({ sequenceNumber: 1, action: "vote_cast", actorId: "u1", actorHandle: "a", optionTitle: "A", accepted: "1", preferred: "1" })
    const data: VerifyData = {
      decision: { ...baseDecision },
      audit_chain: [entry],
      results: [
        { position: 1, option_title: "A", accepted_yes: 1, preferred: 99, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(false)
    expect(result.errors.some((e) => e.includes("preference count"))).toBe(true)
  })

  it("handles vote_updated correctly (last vote per actor wins)", async () => {
    const e1 = await makeEntry({ sequenceNumber: 1, action: "vote_cast", actorId: "u1", actorHandle: "a", optionTitle: "A", accepted: "0", preferred: "0" })
    const e2 = await makeEntry({ sequenceNumber: 2, action: "vote_updated", actorId: "u1", actorHandle: "a", optionTitle: "A", accepted: "1", preferred: "1", previousHash: e1.entry_hash })
    const data: VerifyData = {
      decision: { ...baseDecision },
      audit_chain: [e1, e2],
      results: [
        { position: 1, option_title: "A", accepted_yes: 1, preferred: 1, lottery_sort_key: null },
      ],
    }

    const result = verifyVoteTallies(data)
    expect(result.valid).toBe(true)
  })

  it("passes with no votes", () => {
    const data: VerifyData = {
      decision: { ...baseDecision, subtype: "lottery" },
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

    const sortKey = await sha256hex(randomness + "Option A")

    const data: VerifyData = {
      decision: {
        ...baseDecision,
        subtype: "lottery",
        deadline,
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
        ...baseDecision,
        subtype: "lottery",
        deadline,
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
        ...baseDecision,
        subtype: "lottery",
        deadline,
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
        ...baseDecision,
        subtype: "lottery",
        deadline,
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
      decision: { ...baseDecision },
      audit_chain: [],
    }

    const result = await verifyBeacon(data)
    expect(result.valid).toBe(true)
    expect(result.skipped).toBe(true)
    expect(result.errors.some((e) => e.includes("No beacon drawn yet"))).toBe(true)
  })
})

describe("cross-implementation hash consistency", () => {
  // Reference hash computed by Ruby:
  //   Digest::SHA256.hexdigest("v2||1|vote_cast|tok|Option A|1|0||2026-05-05T12:00:00Z")
  // Verifies that the JS hash matches Ruby and Python for a known input.
  const REFERENCE_HASH = "8767b1bdffca79f17d37f7c0957e5d7e92a0dfa3c6ad9e85b2f54d02122436ca"

  it("computes the same hash as Ruby and Python for a known input", async () => {
    const entry: AuditEntry = {
      schema_version: 2,
      sequence_number: 1,
      action: "vote_cast",
      actor_id: "",
      actor_handle: "",
      actor_token: "tok",
      actor_token_salt: "",
      option_title: "Option A",
      accepted: "1",
      preferred: "0",
      metadata: "",
      previous_hash: "",
      entry_hash: "",
      created_at: "2026-05-05T12:00:00Z",
    }
    const hash = await computeEntryHash(entry)
    expect(hash).toBe(REFERENCE_HASH)
  })

  it("handles Unicode NFC normalization consistently", async () => {
    // "é" can be encoded as U+00E9 (precomposed) or U+0065 U+0301 (decomposed)
    // NFC normalization should produce the same hash for both
    const baseEntry: AuditEntry = {
      schema_version: 2,
      sequence_number: 1,
      action: "option_added",
      actor_id: "",
      actor_handle: "",
      actor_token: "",
      actor_token_salt: "",
      option_title: "",
      accepted: "",
      preferred: "",
      metadata: "",
      previous_hash: "",
      entry_hash: "",
      created_at: "2026-05-05T12:00:00Z",
    }
    const hashNFC = await computeEntryHash({ ...baseEntry, option_title: "é" }) // precomposed é (U+00E9)
    const hashNFD = await computeEntryHash({ ...baseEntry, option_title: "é" }) // decomposed e + combining acute (U+0065 U+0301)
    expect(hashNFC).toBe(hashNFD)
  })
})

describe("verifyAll", () => {
  it("returns combined results", async () => {
    const data: VerifyData = {
      decision: { ...baseDecision },
      audit_chain: [],
    }

    const result = await verifyAll(data)
    expect(result.valid).toBe(true)
    expect(result.chain.valid).toBe(true)
    expect(result.voteTallies.valid).toBe(true)
    expect(result.beacon.valid).toBe(true)
  })
})

describe("verifyActorBinding", () => {
  it("returns 'verified' when token matches the recomputed derivation", async () => {
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
      optionTitle: "Option A",
    })
    expect(await verifyActorBinding(entry, DECISION_ID)).toBe("verified")
  })

  it("returns 'unattributable' when actor_id has been scrubbed", async () => {
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
    })
    // Simulate scrub: NULL actor_id and salt; keep token (it's in the hash and immutable)
    entry.actor_id = ""
    entry.actor_token_salt = ""
    expect(await verifyActorBinding(entry, DECISION_ID)).toBe("unattributable")
  })

  it("returns 'imported' when salt is NULL and metadata flags the entry as imported", async () => {
    // Build the entry with the imported metadata flag baked in so the
    // recomputed hash matches (in production the importer doesn't recompute
    // hashes, but this test isolates verifier logic from import-flow effects).
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
      metadata: JSON.stringify({ imported: true }),
    })
    // Salt isn't in the hash; nulling it doesn't affect entry_hash.
    entry.actor_token_salt = ""
    expect(await verifyActorBinding(entry, DECISION_ID)).toBe("imported")
  })

  it("returns 'tamper_or_scrub_inconsistent' when actor_id was changed without scrub", async () => {
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "vote_cast",
      actorId: "user-1",
      actorHandle: "alice",
    })
    // Tamper: swap actor_id to a different user without recomputing token
    entry.actor_id = "user-2"
    expect(await verifyActorBinding(entry, DECISION_ID)).toBe("tamper_or_scrub_inconsistent")
  })

  it("returns 'no_actor' for system entries without an actor_token", async () => {
    const entry = await makeEntry({
      sequenceNumber: 1,
      action: "beacon_drawn",
    })
    expect(await verifyActorBinding(entry, DECISION_ID)).toBe("no_actor")
  })
})
