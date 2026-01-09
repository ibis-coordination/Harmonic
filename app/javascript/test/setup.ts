import { afterEach } from "vitest"

// Clean up DOM after each test
afterEach(() => {
  document.body.innerHTML = ""
})

/**
 * Wait for Stimulus controllers to connect.
 * Stimulus uses MutationObservers which process asynchronously.
 * This flushes the microtask queue to allow controllers to connect.
 */
export async function waitForController(): Promise<void> {
  // Flush microtasks to allow MutationObserver callbacks to run
  await new Promise((resolve) => setTimeout(resolve, 0))
}
