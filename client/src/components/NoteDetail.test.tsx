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
  NotesService: {
    get: vi.fn(),
    confirmRead: vi.fn(),
  },
  runApiEffect: (...args: unknown[]) => mockRunApiEffect(...args),
}))

// Import the component after mocks are set up
import { NoteDetail } from "./NoteDetail"

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

describe("NoteDetail", () => {
  const mockNote = {
    id: "550e8400-e29b-41d4-a716-446655440000",
    truncated_id: "243bd083",
    title: "E2E Test Note",
    text: "# E2E Test Note\n\nThis is a test note with markdown content.",
    deadline: "2026-01-19T07:31:54.000Z",
    confirmed_reads: 5,
    created_at: "2026-01-19T07:31:54.000Z",
    updated_at: "2026-01-19T07:31:54.000Z",
    created_by_id: "user-123",
    updated_by_id: "user-123",
    commentable_type: null,
    commentable_id: null,
    history_events: [
      {
        id: "event-1",
        note_id: "550e8400-e29b-41d4-a716-446655440000",
        user_id: "user-123",
        event_type: "create",
        description: "created this note",
        happened_at: "2026-01-19T07:31:54.000Z",
      },
      {
        id: "event-2",
        note_id: "550e8400-e29b-41d4-a716-446655440000",
        user_id: "user-456",
        event_type: "read_confirmation",
        description: "confirmed reading this note",
        happened_at: "2026-01-19T08:00:00.000Z",
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

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      expect(screen.getByText(/loading/i)).toBeInTheDocument()
    })
  })

  describe("note title", () => {
    it("displays Note: {title} heading", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { level: 1, name: /note: e2e test note/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays Note: (untitled) when title is null", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockNote,
        title: null,
      })

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { level: 1, name: /note: \(untitled\)/i }),
        ).toBeInTheDocument()
      })
    })
  })

  describe("metadata", () => {
    it("displays created_at timestamp", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        // Check for the Created label and a date in the metadata
        expect(screen.getByText("Created")).toBeInTheDocument()
        expect(screen.getByText("Updated")).toBeInTheDocument()
      })
    })

    it("displays deadline when present", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(screen.getByText(/deadline/i)).toBeInTheDocument()
      })
    })

    it("does not display deadline when null", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockNote,
        deadline: null,
      })

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(screen.queryByText(/deadline/i)).not.toBeInTheDocument()
      })
    })

    it("displays confirmed reads count", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(screen.getByText(/5 confirmed reads/i)).toBeInTheDocument()
      })
    })
  })

  describe("text content", () => {
    it("displays note text content", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(
          screen.getByText(/this is a test note with markdown content/i),
        ).toBeInTheDocument()
      })
    })
  })

  describe("history section", () => {
    it("displays History heading", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /history/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays history events", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(screen.getByText(/created this note/i)).toBeInTheDocument()
        expect(screen.getByText(/confirmed reading this note/i)).toBeInTheDocument()
      })
    })

    it("shows empty state when no history events", async () => {
      mockRunApiEffect.mockResolvedValueOnce({
        ...mockNote,
        history_events: [],
      })

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(screen.getByText(/no history events/i)).toBeInTheDocument()
      })
    })
  })

  describe("actions section", () => {
    it("displays Actions heading", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /actions/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays confirm read button", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockNote)

      renderWithProviders(
        <NoteDetail noteId="243bd083" />,
      )

      await waitFor(() => {
        expect(
          screen.getByRole("button", { name: /confirm read/i }),
        ).toBeInTheDocument()
      })
    })
  })

  describe("error handling", () => {
    it("displays error message when fetch fails", async () => {
      mockRunApiEffect.mockRejectedValueOnce(new Error("Note not found"))

      renderWithProviders(
        <NoteDetail noteId="invalid-id" />,
      )

      await waitFor(() => {
        expect(screen.getByText(/error/i)).toBeInTheDocument()
      })
    })
  })
})
