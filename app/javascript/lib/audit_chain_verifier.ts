import type {
  VerifyData,
  AuditEntry,
  ChainResult,
  VoteTalliesResult,
  BeaconResult,
  VerificationResult,
} from "./audit_chain_types"

// drand quicknet chain parameters (public, independently verifiable)
const DRAND_GENESIS_TIME = 1692803367
const DRAND_PERIOD = 3

async function sha256hex(input: string): Promise<string> {
  const encoder = new TextEncoder()
  const data = encoder.encode(input)
  const hashBuffer = await crypto.subtle.digest("SHA-256", data)
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

function hashInputV1(entry: AuditEntry): string {
  const normalizedTitle = entry.option_title ? entry.option_title.normalize("NFC") : ""
  return [
    "v1",
    entry.previous_hash,
    String(entry.sequence_number),
    entry.action,
    entry.actor_id,
    entry.actor_handle,
    normalizedTitle,
    entry.accepted,
    entry.preferred,
    entry.metadata,
    entry.created_at,
  ].join("|")
}

export async function computeEntryHash(entry: AuditEntry): Promise<string> {
  return sha256hex(hashInputV1(entry))
}

export async function verifyChain(data: VerifyData): Promise<ChainResult> {
  const entries = data.audit_chain
  const errors: string[] = []
  let previousHash = ""

  for (const entry of entries) {
    const computed = await sha256hex(hashInputV1(entry))

    if (computed !== entry.entry_hash) {
      errors.push(`Entry #${entry.sequence_number}: hash mismatch`)
    }
    if (entry.previous_hash !== previousHash) {
      errors.push(`Entry #${entry.sequence_number}: chain link broken`)
    }
    previousHash = entry.entry_hash
  }

  const chainHash = data.decision.audit_chain_hash
  if (chainHash && entries.length > 0) {
    const lastHash = entries[entries.length - 1].entry_hash
    if (chainHash !== lastHash) {
      errors.push("Final chain hash mismatch")
    }
  }

  return {
    valid: errors.length === 0,
    entryCount: entries.length,
    errors,
    lastHash: entries.length > 0 ? entries[entries.length - 1].entry_hash : null,
  }
}

export function verifyVoteTallies(data: VerifyData): VoteTalliesResult {
  const errors: string[] = []
  const results = data.results

  // If no results and no votes, nothing to verify yet
  if (!results) {
    return { valid: true, skipped: true, errors: ["No votes have been cast yet — vote tally verification will be available after voting begins."] }
  }

  // Replay votes: keep latest per (actor_id, option_title) pair
  const votes = new Map<string, { accepted: number; preferred: number }>()
  for (const entry of data.audit_chain) {
    if (entry.action === "vote_cast" || entry.action === "vote_updated") {
      const key = `${entry.actor_id}|${entry.option_title}`
      votes.set(key, {
        accepted: parseInt(entry.accepted) || 0,
        preferred: parseInt(entry.preferred) || 0,
      })
    }
  }

  // Sum totals per option
  const totals = new Map<string, { accepted: number; preferred: number }>()
  for (const [key, vote] of votes) {
    const optionTitle = key.split("|").slice(1).join("|")
    const current = totals.get(optionTitle) ?? { accepted: 0, preferred: 0 }
    current.accepted += vote.accepted
    current.preferred += vote.preferred
    totals.set(optionTitle, current)
  }

  // Compare against results
  for (const result of results) {
    const expected = totals.get(result.option_title) ?? { accepted: 0, preferred: 0 }
    if (result.accepted_yes !== expected.accepted) {
      errors.push(
        `'${result.option_title}' acceptance count is ${result.accepted_yes}, audit chain shows ${expected.accepted}`,
      )
    }
    if (result.preferred !== expected.preferred) {
      errors.push(
        `'${result.option_title}' preference count is ${result.preferred}, audit chain shows ${expected.preferred}`,
      )
    }
  }

  return { valid: errors.length === 0, skipped: false, errors }
}

export async function verifyBeacon(
  data: VerifyData,
  fetchRandomness?: (round: number) => Promise<string>,
): Promise<BeaconResult> {
  const errors: string[] = []

  if (!data.beacon) {
    return { valid: true, skipped: true, errors: ["No beacon drawn yet — beacon verification will be available after the decision closes."] }
  }

  // Derive expected round from deadline
  if (!data.decision.deadline) {
    errors.push("Decision has no deadline — cannot derive expected beacon round")
    return { valid: false, skipped: false, errors }
  }

  const deadlineUnix = Math.floor(new Date(data.decision.deadline).getTime() / 1000)
  if (Number.isNaN(deadlineUnix)) {
    errors.push("Decision deadline is invalid — cannot derive expected beacon round")
    return { valid: false, skipped: false, errors }
  }

  const expectedRound = Math.floor((deadlineUnix - DRAND_GENESIS_TIME) / DRAND_PERIOD) + 2

  if (data.beacon.round !== expectedRound) {
    errors.push(
      `Server claims round ${data.beacon.round}, deadline implies round ${expectedRound}`,
    )
  }

  // Fetch randomness from drand if callback provided
  if (fetchRandomness) {
    let fetchedRandomness: string
    try {
      fetchedRandomness = await fetchRandomness(expectedRound)
    } catch {
      return { valid: true, skipped: true, errors: ["Could not reach the drand randomness beacon to verify sort keys. This does not indicate a problem with the decision — the drand API may be temporarily unavailable. You can verify the beacon independently using the Python script below."] }
    }

    if (fetchedRandomness !== data.beacon.randomness) {
      errors.push(
        `Beacon randomness does not match drand`,
      )
    }

    // Verify sort keys
    if (data.results) {
      for (const result of data.results) {
        if (!result.lottery_sort_key) continue
        const normalizedTitle = result.option_title.normalize("NFC")
        const computed = await sha256hex(fetchedRandomness + normalizedTitle)
        if (computed !== result.lottery_sort_key) {
          errors.push(`Sort key mismatch for '${result.option_title}'`)
        }
      }
    }
  }

  return { valid: errors.length === 0, skipped: false, errors }
}

export async function verifyAll(
  data: VerifyData,
  fetchRandomness?: (round: number) => Promise<string>,
): Promise<VerificationResult> {
  const chain = await verifyChain(data)
  const voteTallies = verifyVoteTallies(data)
  const beacon = await verifyBeacon(data, fetchRandomness)

  return {
    valid: chain.valid && voteTallies.valid && beacon.valid,
    chain,
    voteTallies,
    beacon,
  }
}
