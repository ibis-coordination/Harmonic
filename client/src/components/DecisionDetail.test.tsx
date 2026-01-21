import { describe, it, expect, vi, beforeEach } from "vitest"
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
  DecisionsService: {
    get: vi.fn(),
    vote: vi.fn(),
  },
  runApiEffect: (...args: unknown[]) => mockRunApiEffect(...args),
}))

// Import the component after mocks are set up
import { DecisionDetail } from "./DecisionDetail"

function createTestQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
      },
    },
  })
}

function renderWithProviders(ui: React.ReactNode): ReturnType<typeof render> {
  const queryClient = createTestQueryClient()
  return render(
    <QueryClientProvider client={queryClient}>{ui}</QueryClientProvider>,
  )
}

describe("DecisionDetail", () => {
  const mockDecision = {
    id: 1,
    truncated_id: "8d3d2c55",
    question: "What should we have for Taco Tuesday?",
    description: "Let's decide on the taco filling options for this week.",
    options_open: true,
    deadline: "2026-01-20T23:59:59.000Z",
    created_at: "2026-01-19T07:32:38.000Z",
    updated_at: "2026-01-19T07:32:38.000Z",
    voter_count: 1,
    options: [
      {
        id: 1,
        random_id: "992123456",
        title: "Carnitas",
        description: null,
        decision_id: 1,
        decision_participant_id: 1,
        created_at: "2026-01-19T07:32:38.000Z",
        updated_at: "2026-01-19T07:32:38.000Z",
      },
      {
        id: 2,
        random_id: "263789012",
        title: "Barbacoa",
        description: null,
        decision_id: 1,
        decision_participant_id: 1,
        created_at: "2026-01-19T07:32:38.000Z",
        updated_at: "2026-01-19T07:32:38.000Z",
      },
      {
        id: 3,
        random_id: "190345678",
        title: "Al Pastor",
        description: "Marinated pork with pineapple",
        decision_id: 1,
        decision_participant_id: 1,
        created_at: "2026-01-19T07:32:38.000Z",
        updated_at: "2026-01-19T07:32:38.000Z",
      },
    ],
    results: [
      {
        position: 1,
        decision_id: 1,
        option_id: 1,
        option_title: "Carnitas",
        option_random_id: "992123456",
        accepted_yes: 1,
        accepted_no: 0,
        vote_count: 1,
        preferred: 1,
      },
      {
        position: 2,
        decision_id: 1,
        option_id: 2,
        option_title: "Barbacoa",
        option_random_id: "263789012",
        accepted_yes: 1,
        accepted_no: 0,
        vote_count: 1,
        preferred: 0,
      },
      {
        position: 3,
        decision_id: 1,
        option_id: 3,
        option_title: "Al Pastor",
        option_random_id: "190345678",
        accepted_yes: 0,
        accepted_no: 1,
        vote_count: 1,
        preferred: 0,
      },
    ],
  }

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
      currentSuperagent: { handle: "taco-tuesday", name: "Taco Tuesday" },
      csrfToken: "csrf-token",
    })
  })

  describe("loading state", () => {
    it("displays loading indicator while fetching", () => {
      mockRunApiEffect.mockImplementation(() => new Promise(() => {}))

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      expect(screen.getByText(/loading/i)).toBeInTheDocument()
    })
  })

  describe("decision title", () => {
    it("displays Decision: {question} heading", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", {
            level: 1,
            name: /decision: what should we have for taco tuesday\?/i,
          }),
        ).toBeInTheDocument()
      })
    })

    it("displays Decision: (untitled) when question is empty", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockDecision,
        question: "",
      })

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", {
            level: 1,
            name: /decision: \(untitled\)/i,
          }),
        ).toBeInTheDocument()
      })
    })
  })

  describe("metadata", () => {
    it("displays created_at timestamp", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(screen.getByText("Created")).toBeInTheDocument()
      })
    })

    it("displays deadline when present", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(screen.getByText("Deadline")).toBeInTheDocument()
      })
    })

    it("does not display deadline when null", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockDecision,
        deadline: null,
      })

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(screen.getByText("Created")).toBeInTheDocument()
      })

      expect(screen.queryByText("Deadline")).not.toBeInTheDocument()
    })

    it("displays voter count", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(screen.getByText(/1 voter/i)).toBeInTheDocument()
      })
    })
  })

  describe("description section", () => {
    it("displays description when present", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(
          screen.getByText(
            /let's decide on the taco filling options for this week/i,
          ),
        ).toBeInTheDocument()
      })
    })

    it("does not display description section when null", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockDecision,
        description: null,
      })

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { level: 1 }),
        ).toBeInTheDocument()
      })

      expect(
        screen.queryByText(
          /let's decide on the taco filling options for this week/i,
        ),
      ).not.toBeInTheDocument()
    })
  })

  describe("options section", () => {
    it("displays Options heading", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /options/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays all option titles", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        // Options appear in both the options list and results table
        expect(screen.getAllByText("Carnitas").length).toBeGreaterThanOrEqual(1)
        expect(screen.getAllByText("Barbacoa").length).toBeGreaterThanOrEqual(1)
        expect(screen.getAllByText("Al Pastor").length).toBeGreaterThanOrEqual(1)
      })
    })

    it("displays option description when present", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(
          screen.getByText(/marinated pork with pineapple/i),
        ).toBeInTheDocument()
      })
    })

    it("shows empty state when no options", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockDecision,
        options: [],
      })

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(screen.getByText(/no options yet/i)).toBeInTheDocument()
      })
    })
  })

  describe("results section", () => {
    it("displays Results heading", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /results/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays results table with acceptance counts", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        // Check that the results table headers are present
        expect(screen.getByText("Position")).toBeInTheDocument()
        expect(screen.getByText("Option")).toBeInTheDocument()
      })
    })

    it("shows empty state when no results", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockDecision,
        results: [],
      })

      renderWithProviders(<DecisionDetail decisionId="8d3d2c55" />)

      await waitFor(() => {
        expect(screen.getByText(/no votes yet/i)).toBeInTheDocument()
      })
    })
  })

  describe("error handling", () => {
    it("displays error message when fetch fails", async () => {
      mockRunApiEffect.mockRejectedValueOnce(new Error("Decision not found"))

      renderWithProviders(<DecisionDetail decisionId="invalid-id" />)

      await waitFor(() => {
        expect(screen.getByText(/error/i)).toBeInTheDocument()
      })
    })
  })
})
