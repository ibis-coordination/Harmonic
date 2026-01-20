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
    list: vi.fn(),
  },
  runApiEffect: (...args: unknown[]) => mockRunApiEffect(...args),
}))

// Import the component after mocks are set up
import { IndexComponent } from "./index"

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

describe("IndexComponent (Homepage)", () => {
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
      currentSuperagent: { handle: null, name: null },
      csrfToken: "csrf-token",
    })
  })

  describe("page title", () => {
    it("displays the tenant domain", async () => {
      mockRunApiEffect.mockResolvedValue([])

      renderWithProviders(<IndexComponent />)

      await waitFor(() => {
        expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(
          "app.harmonic.local",
        )
      })
    })
  })

  describe("Your Studios section", () => {
    it("displays the Your Studios heading", async () => {
      mockRunApiEffect.mockResolvedValue([])

      renderWithProviders(<IndexComponent />)

      await waitFor(() => {
        expect(
          screen.getByRole("heading", { name: /your studios/i }),
        ).toBeInTheDocument()
      })
    })

    it("displays a list of studios when available", async () => {
      const mockStudios = [
        { id: 1, handle: "studio-one", name: "Studio One", description: null },
        { id: 2, handle: "studio-two", name: "Studio Two", description: null },
      ]
      mockRunApiEffect.mockResolvedValue(mockStudios)

      renderWithProviders(<IndexComponent />)

      await waitFor(() => {
        expect(screen.getByText("Studio One")).toBeInTheDocument()
        expect(screen.getByText("Studio Two")).toBeInTheDocument()
      })
    })

    it("renders studio links with correct paths", async () => {
      const mockStudios = [
        { id: 1, handle: "studio-one", name: "Studio One", description: null },
      ]
      mockRunApiEffect.mockResolvedValue(mockStudios)

      renderWithProviders(<IndexComponent />)

      await waitFor(() => {
        const studioLink = screen.getByRole("link", { name: "Studio One" })
        expect(studioLink).toHaveAttribute("href", "/studios/studio-one")
      })
    })

    it("shows empty state when no studios", async () => {
      mockRunApiEffect.mockResolvedValue([])

      renderWithProviders(<IndexComponent />)

      await waitFor(() => {
        expect(screen.getByText(/no studios yet/i)).toBeInTheDocument()
      })
    })
  })

  describe("Actions section", () => {
    it("displays link to create new studio", async () => {
      mockRunApiEffect.mockResolvedValue([])

      renderWithProviders(<IndexComponent />)

      await waitFor(() => {
        const newStudioLink = screen.getByRole("link", { name: /new studio/i })
        expect(newStudioLink).toBeInTheDocument()
        expect(newStudioLink).toHaveAttribute("href", "/studios/new")
      })
    })
  })
})
