import type { User } from "@/services/types"

export interface HarmonicContext {
  currentUser: User | null
  currentTenant: { subdomain: string | null; name: string | null }
  currentSuperagent: { handle: string | null; name: string | null }
  csrfToken: string
  apiBasePath: string
}

declare global {
  interface Window {
    __HARMONIC_CONTEXT__?: HarmonicContext
  }
}

export function getHarmonicContext(): HarmonicContext {
  return (
    window.__HARMONIC_CONTEXT__ ?? {
      currentUser: null,
      currentTenant: { subdomain: null, name: null },
      currentSuperagent: { handle: null, name: null },
      csrfToken: "",
      apiBasePath: "/api/v1",
    }
  )
}
