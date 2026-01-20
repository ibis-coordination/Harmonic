export interface User {
  id: number
  user_type: "person" | "subagent" | "trustee"
  email: string | null
  display_name: string
  handle: string
}

export interface Note {
  id: string
  truncated_id: string
  title: string | null
  text: string
  deadline: string | null
  confirmed_reads: number
  created_at: string
  updated_at: string
  created_by_id: string | null
  updated_by_id: string | null
  commentable_type: string | null
  commentable_id: string | null
  history_events?: NoteHistoryEvent[]
  backlinks?: Backlink[]
}

export interface NoteHistoryEvent {
  id: string
  note_id: string
  user_id: string | null
  event_type: string
  description: string
  happened_at: string
}

export interface Backlink {
  id: string
  source_type: string
  source_id: string
  target_type: string
  target_id: string
}

export interface Decision {
  id: number
  truncated_id: string
  question: string
  description: string | null
  options_open: boolean
  deadline: string | null
  created_at: string
  updated_at: string
  voter_count: number
  // Included via ?include=options
  options?: DecisionOption[]
  // Included via ?include=participants
  participants?: DecisionParticipant[]
  // Included via ?include=votes
  votes?: DecisionVote[]
  // Included via ?include=results
  results?: DecisionResult[]
  // Included via ?include=backlinks
  backlinks?: Backlink[]
}

export interface DecisionOption {
  id: number
  random_id: string
  title: string
  description: string | null
  decision_id: number
  decision_participant_id: number
  created_at: string
  updated_at: string
}

export interface DecisionParticipant {
  id: number
  decision_id: number
  user_id: number | null
  created_at: string
  votes?: DecisionVote[]
}

export interface DecisionVote {
  id: number
  option_id: number
  decision_id: number
  decision_participant_id: number
  accepted: 0 | 1
  preferred: 0 | 1
  created_at: string
  updated_at: string
}

export interface DecisionResult {
  position: number
  decision_id: number
  option_id: number
  option_title: string
  option_random_id: string
  accepted_yes: number
  accepted_no: number
  vote_count: number
  preferred: number
}

export interface Commitment {
  id: number
  truncated_id: string
  title: string | null
  text: string
  critical_mass: number
  deadline: string | null
  created_at: string
  updated_at: string
  author: User
  participants: CommitmentParticipant[]
}

export interface CommitmentParticipant {
  id: number
  user: User
  joined_at: string
}

export interface Cycle {
  name: string
  display_name: string
  time_window: string
  unit: string
  start_date: string
  end_date: string
  counts: {
    notes: number
    decisions: number
    commitments: number
  }
  notes?: Note[]
  decisions?: Decision[]
  commitments?: Commitment[]
}

export interface Studio {
  id: number
  handle: string
  name: string
  description: string | null
}
