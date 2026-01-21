import { describe, it, expect, beforeEach, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { Layout } from "./Layout"
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

describe("Layout", () => {
  beforeEach(() => {
    // Reset store state before each test
    useAppStore.setState({
      currentUser: null,
      currentTenant: { subdomain: null, name: null },
      currentSuperagent: { handle: null, name: null },
      csrfToken: "",
    })
  })

  it("renders children", () => {
    render(
      <Layout>
        <div data-testid="child-content">Hello World</div>
      </Layout>,
    )

    expect(screen.getByTestId("child-content")).toBeInTheDocument()
    expect(screen.getByText("Hello World")).toBeInTheDocument()
  })

  it("renders Header component", () => {
    render(
      <Layout>
        <div>Content</div>
      </Layout>,
    )

    // Header should render the Harmonic logo link
    expect(screen.getByRole("link", { name: "Harmonic" })).toBeInTheDocument()
  })

  it("wraps content in main element", () => {
    render(
      <Layout>
        <div>Content</div>
      </Layout>,
    )

    const main = screen.getByRole("main")
    expect(main).toBeInTheDocument()
    expect(main).toContainHTML("Content")
  })

  it("applies layout styling classes", () => {
    const { container } = render(
      <Layout>
        <div>Content</div>
      </Layout>,
    )

    // Check for min-h-screen class on the outer div
    const outerDiv = container.firstChild as HTMLElement
    expect(outerDiv).toHaveClass("min-h-screen")
    expect(outerDiv).toHaveClass("bg-gray-50")
  })
})
