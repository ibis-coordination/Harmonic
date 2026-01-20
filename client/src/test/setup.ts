import "@testing-library/jest-dom/vitest"

// Mock window.__HARMONIC_CONTEXT__ for tests
beforeEach(() => {
  window.__HARMONIC_CONTEXT__ = undefined
})
