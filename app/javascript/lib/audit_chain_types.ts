export interface AuditEntry {
  sequence_number: number
  action: string
  actor_id: string
  actor_handle: string
  option_title: string
  accepted: string
  preferred: string
  metadata: string
  previous_hash: string
  entry_hash: string
  created_at: string
}

export interface DecisionMeta {
  id: string
  question: string
  subtype: string
  deadline: string
  audit_chain_hash: string | null
  lottery_beacon_round: number | null
  lottery_beacon_randomness: string | null
}

export interface BeaconInfo {
  round: number
  randomness: string
  verification_url: string
}

export interface ResultEntry {
  position: number
  option_title: string
  accepted_yes: number
  preferred: number
  lottery_sort_key: string | null
}

export interface VerifyData {
  decision: DecisionMeta
  audit_chain: AuditEntry[]
  beacon?: BeaconInfo
  results?: ResultEntry[]
}

export interface ChainResult {
  valid: boolean
  entryCount: number
  errors: string[]
  lastHash: string | null
}

export interface VoteTalliesResult {
  valid: boolean
  skipped: boolean
  errors: string[]
}

export interface BeaconResult {
  valid: boolean
  skipped: boolean
  errors: string[]
}

export interface VerificationResult {
  valid: boolean
  chain: ChainResult
  voteTallies: VoteTalliesResult
  beacon: BeaconResult
}
