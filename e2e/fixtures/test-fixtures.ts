import { test as base, Page, expect } from "@playwright/test"
import { E2E_TEST_EMAIL, E2E_TEST_PASSWORD } from "../helpers/auth"

/**
 * Test user data
 */
export interface TestUser {
  email: string
  password: string
}

/**
 * Pre-configured E2E test user.
 * Created by `rake e2e:setup` before running tests.
 */
export const testUser: TestUser = {
  email: E2E_TEST_EMAIL,
  password: E2E_TEST_PASSWORD,
}

/**
 * Extended test fixtures with authentication support
 */
export const test = base.extend<{
  authenticatedPage: Page
  testUser: TestUser
}>({
  /**
   * Provides the pre-configured E2E test user
   */
  testUser: async ({}, use) => {
    await use(testUser)
  },

  /**
   * Provides a page that is already authenticated with the test user.
   * Authentication is handled by global setup - the storageState is
   * pre-loaded, so no login is needed here.
   */
  authenticatedPage: async ({ page }, use) => {
    // Session is already authenticated via storageState from global setup
    await use(page)
  },
})

export { expect }
