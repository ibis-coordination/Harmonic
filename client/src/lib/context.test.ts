import { describe, it, expect, beforeEach } from "vitest"
import { getHarmonicContext, type HarmonicContext } from "./context"

describe("getHarmonicContext", () => {
  beforeEach(() => {
    window.__HARMONIC_CONTEXT__ = undefined
  })

  it("returns default context when window context is undefined", () => {
    const context = getHarmonicContext()

    expect(context).toEqual({
      currentUser: null,
      currentTenant: { subdomain: null, name: null },
      currentSuperagent: { handle: null, name: null },
      csrfToken: "",
      apiBasePath: "/api/v1",
    })
  })

  it("returns window context when defined", () => {
    const mockContext: HarmonicContext = {
      currentUser: {
        id: 1,
        user_type: "person",
        email: "test@example.com",
        display_name: "Test User",
        handle: "testuser",
      },
      currentTenant: { subdomain: "app", name: "Test Tenant" },
      currentSuperagent: { handle: "team", name: "Team Studio" },
      csrfToken: "test-csrf-token",
      apiBasePath: "/api/v1",
    }

    window.__HARMONIC_CONTEXT__ = mockContext

    const context = getHarmonicContext()

    expect(context).toEqual(mockContext)
  })

  it("handles partial user data", () => {
    const mockContext: HarmonicContext = {
      currentUser: {
        id: 1,
        user_type: "subagent",
        email: null,
        display_name: "Bot User",
        handle: "bot",
      },
      currentTenant: { subdomain: "app", name: null },
      currentSuperagent: { handle: null, name: null },
      csrfToken: "token",
      apiBasePath: "/api/v1",
    }

    window.__HARMONIC_CONTEXT__ = mockContext

    const context = getHarmonicContext()

    expect(context.currentUser?.email).toBeNull()
    expect(context.currentTenant.name).toBeNull()
    expect(context.currentSuperagent.handle).toBeNull()
  })
})
