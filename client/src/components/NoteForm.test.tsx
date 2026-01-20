import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { useAppStore } from "@/stores/app"

// Mock TanStack Router
const mockNavigate = vi.fn()
vi.mock("@tanstack/react-router", () => ({
  createFileRoute: () => () => ({ component: null }),
  useNavigate: () => mockNavigate,
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
    create: vi.fn(),
  },
  runApiEffect: (...args: unknown[]) => mockRunApiEffect(...args),
}))

// Import the component after mocks are set up
import { NoteForm } from "./NoteForm"

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

describe("NoteForm", () => {
  const mockCreatedNote = {
    id: "550e8400-e29b-41d4-a716-446655440000",
    truncated_id: "550e8400",
    title: "Test Note",
    text: "This is a test note.",
    deadline: null,
    confirmed_reads: 0,
    created_at: "2026-01-19T07:31:54.000Z",
    updated_at: "2026-01-19T07:31:54.000Z",
    created_by_id: "user-123",
    updated_by_id: "user-123",
    commentable_type: null,
    commentable_id: null,
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

  describe("page heading", () => {
    it("displays New Note heading", () => {
      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      expect(
        screen.getByRole("heading", { level: 1, name: /new note/i }),
      ).toBeInTheDocument()
    })
  })

  describe("form fields", () => {
    it("displays text area for note content", () => {
      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      expect(screen.getByLabelText(/text/i)).toBeInTheDocument()
    })

    it("displays create button", () => {
      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      expect(
        screen.getByRole("button", { name: /create note/i }),
      ).toBeInTheDocument()
    })
  })

  describe("form submission", () => {
    it("calls NotesService.create with text on submit", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockCreatedNote)
      const user = userEvent.setup()

      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      const textArea = screen.getByLabelText(/text/i)
      await user.type(textArea, "This is a test note.")

      const submitButton = screen.getByRole("button", { name: /create note/i })
      await user.click(submitButton)

      await waitFor(() => {
        expect(mockRunApiEffect).toHaveBeenCalled()
      })
    })

    it("disables submit button while creating", async () => {
      mockRunApiEffect.mockImplementation(() => new Promise(() => {}))
      const user = userEvent.setup()

      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      const textArea = screen.getByLabelText(/text/i)
      await user.type(textArea, "Test note")

      const submitButton = screen.getByRole("button", { name: /create note/i })
      await user.click(submitButton)

      await waitFor(() => {
        expect(screen.getByRole("button", { name: /creating/i })).toBeDisabled()
      })
    })

    it("navigates to note detail page after successful creation", async () => {
      mockRunApiEffect.mockResolvedValueOnce(mockCreatedNote)
      const user = userEvent.setup()

      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      const textArea = screen.getByLabelText(/text/i)
      await user.type(textArea, "This is a test note.")

      const submitButton = screen.getByRole("button", { name: /create note/i })
      await user.click(submitButton)

      await waitFor(() => {
        expect(mockNavigate).toHaveBeenCalledWith({
          to: "/studios/$handle/n/$id",
          params: { handle: "taco-tuesday", id: "550e8400" },
        })
      })
    })
  })

  describe("validation", () => {
    it("disables submit button when text is empty", () => {
      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      const submitButton = screen.getByRole("button", { name: /create note/i })
      expect(submitButton).toBeDisabled()
    })

    it("enables submit button when text is provided", async () => {
      const user = userEvent.setup()

      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      const textArea = screen.getByLabelText(/text/i)
      await user.type(textArea, "Some text")

      const submitButton = screen.getByRole("button", { name: /create note/i })
      expect(submitButton).not.toBeDisabled()
    })
  })

  describe("error handling", () => {
    it("displays error message when creation fails", async () => {
      mockRunApiEffect.mockRejectedValueOnce(new Error("Creation failed"))
      const user = userEvent.setup()

      renderWithProviders(<NoteForm handle="taco-tuesday" />)

      const textArea = screen.getByLabelText(/text/i)
      await user.type(textArea, "Test note")

      const submitButton = screen.getByRole("button", { name: /create note/i })
      await user.click(submitButton)

      await waitFor(() => {
        expect(screen.getByText(/error/i)).toBeInTheDocument()
      })
    })
  })
})
