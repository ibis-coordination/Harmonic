import { afterEach } from "vitest"

// Clean up DOM after each test
afterEach(() => {
  document.body.innerHTML = ""
})
