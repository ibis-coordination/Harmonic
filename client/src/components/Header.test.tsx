import { describe, it, expect, beforeEach, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { Header } from "./Header"
import { useAppStore } from "@/stores/app"

// Mock TanStack Router
vi.mock("@tanstack/react-router", () => ({
  Link: ({
    children,
    to,
    params,
  }: {
    children: React.ReactNode
    to: string
    params?: Record<string, string>
  }) => {
    const href =
      params && to.includes("$")
        ? to.replace(/\$(\w+)/g, (_, key) => params[key] ?? "")
        : to
    return <a href={href}>{children}</a>
  },
}))

describe("Header", () => {
  beforeEach(() => {
    // Reset store state before each test
    useAppStore.setState({
      currentUser: null,
      currentTenant: { subdomain: null, name: null },
      currentSuperagent: { handle: null, name: null },
      csrfToken: "",
    })
  })

  describe("when user is not logged in", () => {
    it("renders Harmonic logo link", () => {
      render(<Header />)

      const logoLink = screen.getByRole("link", { name: "Harmonic" })
      expect(logoLink).toBeInTheDocument()
      expect(logoLink).toHaveAttribute("href", "/")
    })

    it("renders sign in link", () => {
      render(<Header />)

      const signInLink = screen.getByRole("link", { name: "Sign in" })
      expect(signInLink).toBeInTheDocument()
      expect(signInLink).toHaveAttribute("href", "/login")
    })

    it("does not render user info", () => {
      render(<Header />)

      expect(screen.queryByText("Settings")).not.toBeInTheDocument()
      expect(screen.queryByText("Sign out")).not.toBeInTheDocument()
    })

    it("does not render studio link when no superagent", () => {
      render(<Header />)

      // Should only have the Harmonic link and Sign in link
      const links = screen.getAllByRole("link")
      expect(links).toHaveLength(2)
    })
  })

  describe("when user is logged in", () => {
    beforeEach(() => {
      useAppStore.setState({
        currentUser: {
          id: 1,
          user_type: "person",
          email: "test@example.com",
          display_name: "Test User",
          handle: "testuser",
        },
        currentTenant: { subdomain: "app", name: "Test App" },
        currentSuperagent: { handle: null, name: null },
        csrfToken: "csrf-token",
      })
    })

    it("renders user display name", () => {
      render(<Header />)

      expect(screen.getByText("Test User")).toBeInTheDocument()
    })

    it("renders settings link", () => {
      render(<Header />)

      const settingsLink = screen.getByRole("link", { name: "Settings" })
      expect(settingsLink).toBeInTheDocument()
      expect(settingsLink).toHaveAttribute("href", "/u/testuser/settings")
    })

    it("renders sign out link", () => {
      render(<Header />)

      const signOutLink = screen.getByRole("link", { name: "Sign out" })
      expect(signOutLink).toBeInTheDocument()
      expect(signOutLink).toHaveAttribute("href", "/logout")
    })

    it("does not render sign in link", () => {
      render(<Header />)

      expect(screen.queryByText("Sign in")).not.toBeInTheDocument()
    })
  })

  describe("when in a studio context", () => {
    beforeEach(() => {
      useAppStore.setState({
        currentUser: {
          id: 1,
          user_type: "person",
          email: "test@example.com",
          display_name: "Test User",
          handle: "testuser",
        },
        currentTenant: { subdomain: "app", name: "Test App" },
        currentSuperagent: { handle: "team", name: "Team Studio" },
        csrfToken: "csrf-token",
      })
    })

    it("renders studio link with name", () => {
      render(<Header />)

      const studioLink = screen.getByRole("link", { name: "Team Studio" })
      expect(studioLink).toBeInTheDocument()
      expect(studioLink).toHaveAttribute("href", "/studios/team")
    })

    it("renders separator between logo and studio", () => {
      render(<Header />)

      expect(screen.getByText("/")).toBeInTheDocument()
    })
  })

  describe("when studio has no name", () => {
    beforeEach(() => {
      useAppStore.setState({
        currentUser: null,
        currentTenant: { subdomain: null, name: null },
        currentSuperagent: { handle: "mystudio", name: null },
        csrfToken: "",
      })
    })

    it("renders studio handle as fallback", () => {
      render(<Header />)

      const studioLink = screen.getByRole("link", { name: "mystudio" })
      expect(studioLink).toBeInTheDocument()
    })
  })
})
