import { create } from "zustand"
import type { User } from "@/services/types"
import { getHarmonicContext } from "@/lib/context"

interface AppState {
  currentUser: User | null
  currentTenant: { subdomain: string | null; name: string | null }
  currentSuperagent: { handle: string | null; name: string | null }
  csrfToken: string

  setCurrentUser: (user: User | null) => void
  setCurrentSuperagent: (superagent: {
    handle: string | null
    name: string | null
  }) => void
}

const context = getHarmonicContext()

export const useAppStore = create<AppState>((set) => ({
  currentUser: context.currentUser,
  currentTenant: context.currentTenant,
  currentSuperagent: context.currentSuperagent,
  csrfToken: context.csrfToken,

  setCurrentUser: (user) => set({ currentUser: user }),
  setCurrentSuperagent: (superagent) => set({ currentSuperagent: superagent }),
}))
