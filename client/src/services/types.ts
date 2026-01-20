export interface User {
  id: number
  user_type: "person" | "subagent" | "trustee"
  email: string | null
  display_name: string
  handle: string
}

export interface Note {
  id: number
  truncated_id: string
  title: string | null
  text: string
  deadline: string | null
  created_at: string
  updated_at: string
  author: User
  confirmed_users: User[]
}

export interface Decision {
  id: number
  truncated_id: string
  title: string | null
  text: string
  deadline: string | null
  created_at: string
  updated_at: string
  author: User
  options: Option[]
  participants: Participant[]
  results: DecisionResults | null
}

export interface Option {
  id: number
  truncated_id: string
  text: string
  position: number
}

export interface Participant {
  id: number
  user: User
  votes: Vote[]
}

export interface Vote {
  id: number
  option_id: number
  rank: number
}

export interface DecisionResults {
  method: string
  winner: Option | null
  rounds: unknown[]
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
