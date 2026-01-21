import { describe, it, expect, beforeEach, vi } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { useAppStore } from "@/stores/app"

// Mock TanStack Router
vi.mock("@tanstack/react-router", () => ({
  createFileRoute: () => () => ({ component: null }),
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

// Mock the API module
const mockRunApiEffect = vi.fn()
vi.mock("@/services/api", () => ({
  StudiosService: {
    get: vi.fn(),
  },
  UsersService: {
    list: vi.fn(),
  },
  runApiEffect: (...args: unknown[]) => mockRunApiEffect(...args),
}))

// Import the component after mocks are set up
import { StudioOverview } from "./index"

function createTestQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
      },
    },
  })
}

function renderWithProviders(ui: React.ReactNode) {
  const queryClient = createTestQueryClient()
  return render(
    <QueryClientProvider client={queryClient}>{ui}</QueryClientProvider>,
  )
}

describe("StudioOverview", () => {
  const mockStudio = {
    id: 1,
    handle: "test-studio",
    name: "Test Studio",
    description: null,
    timezone: "UTC",
    tempo: "weekly",
  }

  const mockTeamMembers = [
    {
      id: 1,
      user_type: "person" as const,
      email: "dan@example.com",
      display_name: "Dan Allison",
      handle: "dan-allison",
    },
    {
      id: 2,
      user_type: "subagent" as const,
      email: null,
      display_name: "George",
      handle: "george",
    },
  ]

  beforeEach(() => {
    vi.clearAllMocks()
    useAppStore.setState({
      currentUser: {
        id: 1,
        user_type: "person",
        email: "test@example.com",
        display_name: "Test User",
        handle: "testuser",
      },
      currentTenant: { subdomain: "app", name: "Test App" },
      currentSuperagent: { handle: "test-studio", name: "Test Studio" },
      csrfToken: "csrf-token",
    })
  })

  describe("page title", () => {
    it("displays Studio: {name} heading", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { level: 1, name: /studio: test studio/i }),
        ).toBeInTheDocument()
      })
    })
  })

  describe("Explore section", () => {
    it("displays Explore heading", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /explore/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays link to Cycles", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        const cyclesLink = screen.getByRole("link", { name: /cycles/i })
        expect(cyclesLink).toBeInTheDocument()
        expect(cyclesLink).toHaveAttribute(
          "href",
          "/studios/test-studio/cycles",
        )
      })
    })

    it("displays link to Backlinks", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        const backlinksLink = screen.getByRole("link", { name: /backlinks/i })
        expect(backlinksLink).toBeInTheDocument()
        expect(backlinksLink).toHaveAttribute(
          "href",
          "/studios/test-studio/backlinks",
        )
      })
    })
  })

  describe("Pinned section", () => {
    it("displays Pinned heading", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /pinned/i }),
        ).toBeInTheDocument()
      })
    })

    it("shows empty state when no pinned items", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(screen.getByText(/no pinned items yet/i)).toBeInTheDocument()
      })
    })
  })

  describe("Team section", () => {
    it("displays Team heading", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /team/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays team members", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(screen.getByText("Dan Allison")).toBeInTheDocument()
        expect(screen.getByText("George")).toBeInTheDocument()
      })
    })

    it("shows empty state when no team members", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce([])

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(screen.getByText(/no team members yet/i)).toBeInTheDocument()
      })
    })
  })

  describe("Actions section", () => {
    it("displays Actions heading", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /actions/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays link to create new note", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        const newNoteLink = screen.getByRole("link", { name: /new note/i })
        expect(newNoteLink).toBeInTheDocument()
        expect(newNoteLink).toHaveAttribute("href", "/studios/test-studio/note")
      })
    })

    it("displays link to create new decision", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        const newDecisionLink = screen.getByRole("link", {
          name: /new decision/i,
        })
        expect(newDecisionLink).toBeInTheDocument()
        expect(newDecisionLink).toHaveAttribute(
          "href",
          "/studios/test-studio/decide",
        )
      })
    })

    it("displays link to create new commitment", async () => {
      mockRunApiEffect
        .mockResolvedValueOnce(mockStudio)
        .mockResolvedValueOnce(mockTeamMembers)

      renderWithProviders(<StudioOverview handle="test-studio" />)

      await waitFor(() => {
        const newCommitmentLink = screen.getByRole("link", {
          name: /new commitment/i,
        })
        expect(newCommitmentLink).toBeInTheDocument()
        expect(newCommitmentLink).toHaveAttribute(
          "href",
          "/studios/test-studio/commit",
        )
      })
    })
  })
})
