import "@testing-library/jest-dom/vitest"
import { beforeEach } from "vitest"

// Mock window.__HARMONIC_CONTEXT__ for tests
beforeEach(() => {
  delete window.__HARMONIC_CONTEXT__
})
