import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

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
  DecisionsService: {
    create: vi.fn(),
  },
  runApiEffect: (...args: unknown[]) => mockRunApiEffect(...args),
}))

// Import the component after mocks are set up
import { DecisionForm } from "./DecisionForm"

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

describe("DecisionForm", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe("rendering", () => {
    it("renders the form heading", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      expect(screen.getByRole("heading", { name: /new decision/i })).toBeInTheDocument()
    })

    it("renders the question input field", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      expect(screen.getByLabelText(/question/i)).toBeInTheDocument()
    })

    it("renders the description textarea", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      expect(screen.getByLabelText(/description/i)).toBeInTheDocument()
    })

    it("renders the deadline input field", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      expect(screen.getByLabelText(/deadline/i)).toBeInTheDocument()
    })

    it("renders the options open checkbox", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      expect(screen.getByLabelText(/allow anyone to add options/i)).toBeInTheDocument()
    })

    it("renders the submit button", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      expect(screen.getByRole("button", { name: /create decision/i })).toBeInTheDocument()
    })

    it("renders helper text explaining the form", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      expect(screen.getByText(/decisions require a question/i)).toBeInTheDocument()
    })
  })

  describe("form validation", () => {
    it("submit button is disabled when question is empty", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      const submitButton = screen.getByRole("button", { name: /create decision/i })
      expect(submitButton).toBeDisabled()
    })

    it("submit button is enabled when question is entered", async () => {
      const user = userEvent.setup()
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      const questionInput = screen.getByLabelText(/question/i)
      await user.type(questionInput, "What should we order?")

      const submitButton = screen.getByRole("button", { name: /create decision/i })
      expect(submitButton).not.toBeDisabled()
    })

    it("submit button is disabled when question is only whitespace", async () => {
      const user = userEvent.setup()
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      const questionInput = screen.getByLabelText(/question/i)
      await user.type(questionInput, "   ")

      const submitButton = screen.getByRole("button", { name: /create decision/i })
      expect(submitButton).toBeDisabled()
    })
  })

  describe("form submission", () => {
    it("calls create API with question when submitted", async () => {
      const user = userEvent.setup()
      const mockDecision = {
        id: 1,
        truncated_id: "abc123",
        question: "What should we order?",
      }
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      const questionInput = screen.getByLabelText(/question/i)
      await user.type(questionInput, "What should we order?")

      const submitButton = screen.getByRole("button", { name: /create decision/i })
      await user.click(submitButton)

      await waitFor(() => {
        expect(mockRunApiEffect).toHaveBeenCalled()
      })
    })

    it("includes description when provided", async () => {
      const user = userEvent.setup()
      const mockDecision = {
        id: 1,
        truncated_id: "abc123",
        question: "What should we order?",
      }
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      await user.type(screen.getByLabelText(/question/i), "What should we order?")
      await user.type(screen.getByLabelText(/description/i), "For lunch today")

      await user.click(screen.getByRole("button", { name: /create decision/i }))

      await waitFor(() => {
        expect(mockRunApiEffect).toHaveBeenCalled()
      })
    })

    it("includes options_open when checkbox is checked", async () => {
      const user = userEvent.setup()
      const mockDecision = {
        id: 1,
        truncated_id: "abc123",
        question: "What should we order?",
      }
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      await user.type(screen.getByLabelText(/question/i), "What should we order?")
      await user.click(screen.getByLabelText(/allow anyone to add options/i))

      await user.click(screen.getByRole("button", { name: /create decision/i }))

      await waitFor(() => {
        expect(mockRunApiEffect).toHaveBeenCalled()
      })
    })

    it("navigates to decision detail page on success", async () => {
      const user = userEvent.setup()
      const mockDecision = {
        id: 1,
        truncated_id: "abc123",
        question: "What should we order?",
      }
      mockRunApiEffect.mockResolvedValueOnce(mockDecision)

      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      await user.type(screen.getByLabelText(/question/i), "What should we order?")
      await user.click(screen.getByRole("button", { name: /create decision/i }))

      await waitFor(() => {
        expect(mockNavigate).toHaveBeenCalledWith({
          to: "/studios/$handle/d/$id",
          params: { handle: "taco-tuesday", id: "abc123" },
        })
      })
    })

    it("shows loading state while submitting", async () => {
      const user = userEvent.setup()
      mockRunApiEffect.mockImplementation(
        () => new Promise((resolve) => setTimeout(resolve, 100)),
      )

      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      await user.type(screen.getByLabelText(/question/i), "What should we order?")
      await user.click(screen.getByRole("button", { name: /create decision/i }))

      expect(screen.getByRole("button", { name: /creating/i })).toBeInTheDocument()
    })

    it("displays error message on failure", async () => {
      const user = userEvent.setup()
      mockRunApiEffect.mockRejectedValueOnce(new Error("API error"))

      renderWithProviders(<DecisionForm handle="taco-tuesday" />)

      await user.type(screen.getByLabelText(/question/i), "What should we order?")
      await user.click(screen.getByRole("button", { name: /create decision/i }))

      await waitFor(() => {
        expect(screen.getByText(/error creating decision/i)).toBeInTheDocument()
      })
    })
  })

  describe("checkbox default state", () => {
    it("options open checkbox is unchecked by default", () => {
      renderWithProviders(<DecisionForm handle="taco-tuesday" />)
      const checkbox = screen.getByLabelText(/allow anyone to add options/i)
      expect(checkbox).not.toBeChecked()
    })
  })
})
