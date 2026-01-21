import { ReactElement } from "react"
import { render, RenderOptions } from "@testing-library/react"
import {
  RouterProvider,
  createMemoryHistory,
  createRouter,
  createRootRoute,
} from "@tanstack/react-router"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

interface WrapperProps {
  children: React.ReactNode
}

// Create a test query client
function createTestQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
      },
    },
  })
}

// Create a minimal test router
function createTestRouter(component: ReactElement) {
  const rootRoute = createRootRoute({
    component: () => component,
  })

  const router = createRouter({
    routeTree: rootRoute,
    history: createMemoryHistory({ initialEntries: ["/"] }),
  })

  return router
}

// Custom render that wraps with providers
function customRender(
  ui: ReactElement,
  options?: Omit<RenderOptions, "wrapper">,
) {
  const queryClient = createTestQueryClient()

  function Wrapper({ children }: WrapperProps) {
    return (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    )
  }

  return render(ui, { wrapper: Wrapper, ...options })
}

// Render with router for components that use routing
function renderWithRouter(
  ui: ReactElement,
  options?: Omit<RenderOptions, "wrapper">,
) {
  const queryClient = createTestQueryClient()
  const router = createTestRouter(ui)

  // For router-based rendering, we render the RouterProvider wrapped in QueryClientProvider
  return render(
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
    options,
  )
}

export * from "@testing-library/react"
export { customRender as render, renderWithRouter }
