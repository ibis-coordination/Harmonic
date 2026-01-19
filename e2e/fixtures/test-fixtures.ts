import { test as base, Page, expect } from "@playwright/test"
import { login } from "../helpers/auth"

/**
 * Test user data
 */
export interface TestUser {
  email: string
  name: string
}

/**
 * Generate a unique test user for each test
 */
function generateTestUser(): TestUser {
  const timestamp = Date.now()
  const random = Math.random().toString(36).substring(2, 10)
  return {
    email: `e2e-test-${timestamp}-${random}@example.com`,
    name: `E2E User ${timestamp}${random}`,
  }
}

/**
 * Extended test fixtures with authentication support
 */
export const test = base.extend<{
  authenticatedPage: Page
  testUser: TestUser
}>({
  /**
   * Generates a unique test user for each test
   */
  testUser: async ({}, use) => {
    const user = generateTestUser()
    await use(user)
  },

  /**
   * Provides a page that is already authenticated with a test user
   */
  authenticatedPage: async ({ page, testUser }, use) => {
    await login(page, { email: testUser.email, name: testUser.name })
    await use(page)
  },
})

export { expect }
