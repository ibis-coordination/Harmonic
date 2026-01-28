import { test, expect } from "../../fixtures/test-fixtures"
import { buildBaseUrl } from "../../helpers/auth"

/**
 * Helper to navigate to the first available studio's pulse page
 */
async function navigateToPulse(
  page: import("@playwright/test").Page,
): Promise<string | null> {
  const baseUrl = buildBaseUrl()

  // Go to studios list
  await page.goto(`${baseUrl}/studios`)

  // Wait for studios list to load
  await page.locator('a[href*="/studios/"]').first().waitFor({ state: "visible", timeout: 5000 }).catch(() => {})

  // Find the first studio link
  const studioLink = page.locator('a[href*="/studios/"]').first()

  if ((await studioLink.count()) === 0) {
    return null
  }

  // Extract the studio handle from the link
  const href = await studioLink.getAttribute("href")
  const match = href?.match(/\/studios\/([^/]+)/)
  if (!match) {
    return null
  }

  const studioHandle = match[1]

  // Navigate to studio page (Pulse is now the default homepage)
  await page.goto(`${baseUrl}/studios/${studioHandle}`)

  // Wait for pulse page to load
  await page.locator(".pulse-feed").waitFor({ state: "visible", timeout: 5000 }).catch(() => {})

  return studioHandle
}

test.describe("Pulse Activity Feed", () => {
  test.describe("Page Structure", () => {
    test("pulse page renders with studio name", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Check studio name is visible in sidebar
      await expect(page.locator(".pulse-sidebar-studio-name")).toBeVisible()
    })

    test("pulse page shows visibility icon", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Should have a visibility icon (lock or eye)
      const visibilityIcon = page.locator(".pulse-visibility-icon")
      await expect(visibilityIcon).toBeVisible()
    })

    test("pulse page shows new button", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Check for "New" button that links to note creation
      const newButton = page.locator('a.pulse-action-btn:has-text("+ New")')
      await expect(newButton).toBeVisible()

      // Should link to note creation
      const href = await newButton.getAttribute("href")
      expect(href).toContain("/note")
    })

    test("sidebar navigation is visible", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Check sidebar nav exists
      const nav = page.locator(".pulse-nav")
      await expect(nav).toBeVisible()

      // Check for Activity section label
      await expect(
        page.locator('.pulse-section-label:has-text("Activity")'),
      ).toBeVisible()

      // Check for filter buttons (Notes, Decisions, Commitments)
      await expect(
        page.locator('.pulse-nav-item:has-text("Notes")'),
      ).toBeVisible()
      await expect(
        page.locator('.pulse-nav-item:has-text("Decisions")'),
      ).toBeVisible()
      await expect(
        page.locator('.pulse-nav-item:has-text("Commitments")'),
      ).toBeVisible()
    })

    test("sidebar shows members link", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Check for members link in studio meta section
      const membersLink = page.locator('.pulse-member-link')
      await expect(membersLink).toBeVisible()

      // Should link to members page
      const href = await membersLink.getAttribute("href")
      expect(href).toContain("/members")
    })
  })

  test.describe("Feed Items", () => {
    test("feed items display when activity exists", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Either feed items exist or empty state is shown
      const feedItems = page.locator(".pulse-feed-item")
      const emptyState = page.locator(".pulse-feed-empty")

      const hasItems = (await feedItems.count()) > 0
      const isEmpty = (await emptyState.count()) > 0

      expect(hasItems || isEmpty).toBe(true)
    })

    test("feed item has type indicator", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const firstItem = page.locator(".pulse-feed-item").first()

      if ((await firstItem.count()) === 0) {
        test.skip()
        return
      }

      // Should have type indicator with icon
      const typeIndicator = firstItem.locator(".pulse-feed-item-type")
      await expect(typeIndicator).toBeVisible()

      // Should have an icon image
      const icon = typeIndicator.locator("img")
      await expect(icon).toBeVisible()

      // Should have type text (Note, Decision, or Commitment)
      const typeText = await typeIndicator.locator("span").textContent()
      expect(["Note", "Decision", "Commitment"]).toContain(typeText)
    })

    test("feed item has author with avatar", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const firstItem = page.locator(".pulse-feed-item").first()

      if ((await firstItem.count()) === 0) {
        test.skip()
        return
      }

      // Check for author link or anonymous text
      const authorLink = firstItem.locator(".pulse-feed-item-author")
      const anonymousSpan = firstItem.locator(
        '.pulse-feed-item-meta span:has-text("Anonymous")',
      )

      const hasAuthor = (await authorLink.count()) > 0
      const isAnonymous = (await anonymousSpan.count()) > 0

      expect(hasAuthor || isAnonymous).toBe(true)

      if (hasAuthor) {
        // Author should have avatar
        const avatar = authorLink.locator(".pulse-author-avatar")
        await expect(avatar).toBeVisible()

        // Avatar should have initials
        const initials = avatar.locator(".pulse-avatar-initials")
        await expect(initials).toBeVisible()
      }
    })

    test("feed item author links to profile page", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const authorLink = page.locator(".pulse-feed-item-author").first()

      if ((await authorLink.count()) === 0) {
        test.skip()
        return
      }

      // Author link should point to user profile
      const href = await authorLink.getAttribute("href")
      expect(href).toContain("/u/")
    })

    test("feed item has view link", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const firstItem = page.locator(".pulse-feed-item").first()

      if ((await firstItem.count()) === 0) {
        test.skip()
        return
      }

      // Should have view link in footer
      const viewLink = firstItem.locator(".pulse-feed-action-link")
      await expect(viewLink).toBeVisible()
      await expect(viewLink).toContainText("View")
    })

    test("feed item title links to resource", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const titleLink = page
        .locator(".pulse-feed-item-title a, .pulse-feed-item-content a")
        .first()

      if ((await titleLink.count()) === 0) {
        test.skip()
        return
      }

      // Title should link to resource
      const href = await titleLink.getAttribute("href")
      expect(href).toMatch(/\/(n|d|c)\//)
    })
  })

  test.describe("Filtering", () => {
    test("clicking Notes filter shows only notes", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Click Notes filter
      await page
        .locator('.pulse-nav-item[data-filter-type="Note"]')
        .click()

      // Wait for filter to apply
      // Filter applied - assertion below will wait for state

      // Filter indicator should be visible
      const indicator = page.locator(".pulse-filter-indicator")
      await expect(indicator).toBeVisible()
      await expect(
        indicator.locator('[data-pulse-filter-target="indicatorLabel"]'),
      ).toContainText("Notes")

      // Only Note items should be visible
      const allItems = page.locator(".pulse-feed-item")
      const noteItems = page.locator('.pulse-feed-item[data-item-type="Note"]')
      const decisionItems = page.locator(
        '.pulse-feed-item[data-item-type="Decision"]',
      )
      const commitmentItems = page.locator(
        '.pulse-feed-item[data-item-type="Commitment"]',
      )

      // Decision and Commitment items should be hidden
      if ((await decisionItems.count()) > 0) {
        await expect(decisionItems.first()).toBeHidden()
      }
      if ((await commitmentItems.count()) > 0) {
        await expect(commitmentItems.first()).toBeHidden()
      }

      // Note items should be visible (if any exist)
      if ((await noteItems.count()) > 0) {
        await expect(noteItems.first()).toBeVisible()
      }
    })

    test("clicking Decisions filter shows only decisions", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Click Decisions filter
      await page
        .locator('.pulse-nav-item[data-filter-type="Decision"]')
        .click()

      // Wait for filter to apply
      // Filter applied - assertion below will wait for state

      // Filter indicator should show Decisions
      const indicator = page.locator(".pulse-filter-indicator")
      await expect(indicator).toBeVisible()
      await expect(
        indicator.locator('[data-pulse-filter-target="indicatorLabel"]'),
      ).toContainText("Decisions")

      // Only Decision items should be visible
      const noteItems = page.locator('.pulse-feed-item[data-item-type="Note"]')
      const commitmentItems = page.locator(
        '.pulse-feed-item[data-item-type="Commitment"]',
      )

      if ((await noteItems.count()) > 0) {
        await expect(noteItems.first()).toBeHidden()
      }
      if ((await commitmentItems.count()) > 0) {
        await expect(commitmentItems.first()).toBeHidden()
      }
    })

    test("clicking Commitments filter shows only commitments", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Click Commitments filter
      await page
        .locator('.pulse-nav-item[data-filter-type="Commitment"]')
        .click()

      // Wait for filter to apply
      // Filter applied - assertion below will wait for state

      // Filter indicator should show Commitments
      const indicator = page.locator(".pulse-filter-indicator")
      await expect(indicator).toBeVisible()
      await expect(
        indicator.locator('[data-pulse-filter-target="indicatorLabel"]'),
      ).toContainText("Commitments")

      // Only Commitment items should be visible
      const noteItems = page.locator('.pulse-feed-item[data-item-type="Note"]')
      const decisionItems = page.locator(
        '.pulse-feed-item[data-item-type="Decision"]',
      )

      if ((await noteItems.count()) > 0) {
        await expect(noteItems.first()).toBeHidden()
      }
      if ((await decisionItems.count()) > 0) {
        await expect(decisionItems.first()).toBeHidden()
      }
    })

    test("clicking X button clears filter and shows all items", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // First apply a filter
      await page
        .locator('.pulse-nav-item[data-filter-type="Note"]')
        .click()
      // Filter applied - assertion below will wait for state

      // Verify filter is applied
      await expect(page.locator(".pulse-filter-indicator")).toBeVisible()

      // Click X to clear filter
      await page.locator(".pulse-filter-remove").click()
      // Filter applied - assertion below will wait for state

      // Filter indicator should be hidden
      await expect(page.locator(".pulse-filter-indicator")).toBeHidden()

      // All items should be visible
      const allItems = page.locator(".pulse-feed-item")
      if ((await allItems.count()) > 0) {
        await expect(allItems.first()).toBeVisible()
      }
    })

    test("clicking X button removes filter", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // First apply a filter
      await page
        .locator('.pulse-nav-item[data-filter-type="Decision"]')
        .click()
      // Filter applied - assertion below will wait for state

      // Verify filter is applied
      await expect(page.locator(".pulse-filter-indicator")).toBeVisible()

      // Click X to remove filter
      await page.locator(".pulse-filter-remove").click()
      // Filter applied - assertion below will wait for state

      // Filter indicator should be hidden
      await expect(page.locator(".pulse-filter-indicator")).toBeHidden()
    })

    test("filter nav item shows active state", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Click Notes filter
      const notesBtn = page.locator('.pulse-nav-item[data-filter-type="Note"]')
      await notesBtn.click()
      // Filter applied - assertion below will wait for state

      // Notes should be active
      await expect(notesBtn).toHaveClass(/active/)

      // Click Decisions filter
      const decisionsBtn = page.locator('.pulse-nav-item[data-filter-type="Decision"]')
      await decisionsBtn.click()
      // Filter applied - assertion below will wait for state

      // Decisions should be active, Notes should not
      await expect(decisionsBtn).toHaveClass(/active/)
      await expect(notesBtn).not.toHaveClass(/active/)
    })

    test("clicking same filter again toggles it off", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Click Notes filter
      const notesBtn = page.locator('.pulse-nav-item[data-filter-type="Note"]')
      await notesBtn.click()
      // Filter applied - assertion below will wait for state

      // Verify filter is applied
      await expect(page.locator(".pulse-filter-indicator")).toBeVisible()

      // Click Notes again to toggle off
      await notesBtn.click()
      // Filter applied - assertion below will wait for state

      // Filter should be removed
      await expect(page.locator(".pulse-filter-indicator")).toBeHidden()
    })
  })

  test.describe("Note Actions", () => {
    test("note item has confirm read button or confirmed state", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const noteItem = page.locator('.pulse-feed-item[data-item-type="Note"]').first()

      if ((await noteItem.count()) === 0) {
        test.skip()
        return
      }

      // Should have either confirm button or confirmed state
      const confirmBtn = noteItem.locator('button:has-text("Confirm read")')
      const confirmedBtn = noteItem.locator('button:has-text("Confirmed")')

      const hasConfirmBtn = (await confirmBtn.count()) > 0
      const hasConfirmedBtn = (await confirmedBtn.count()) > 0

      expect(hasConfirmBtn || hasConfirmedBtn).toBe(true)
    })

    test("confirm read button performs AJAX action", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const noteItem = page.locator('.pulse-feed-item[data-item-type="Note"]').first()

      if ((await noteItem.count()) === 0) {
        test.skip()
        return
      }

      const confirmBtn = noteItem.locator('button:has-text("Confirm read")')

      if ((await confirmBtn.count()) === 0) {
        // Already confirmed or no notes
        test.skip()
        return
      }

      // Click confirm read
      await confirmBtn.click()

      // Button should change to loading or confirmed state
      await expect(
        noteItem.locator('button:has-text("Confirming...")').or(
          noteItem.locator('button:has-text("Confirmed")'),
        ),
      ).toBeVisible({ timeout: 5000 })

      // Eventually should show confirmed
      await expect(
        noteItem.locator('button:has-text("Confirmed")'),
      ).toBeVisible({ timeout: 10000 })
    })
  })

  test.describe("Decision Display", () => {
    test("open decision shows vote link", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Look for decision that has vote link (open decision)
      const voteLink = page.locator('.pulse-feed-item[data-item-type="Decision"] a.pulse-feed-action-btn-link:has-text("Vote")').first()

      if ((await voteLink.count()) === 0) {
        // No open decisions
        test.skip()
        return
      }

      await expect(voteLink).toBeVisible()

      // Vote link should point to decision
      const href = await voteLink.getAttribute("href")
      expect(href).toMatch(/\/d\//)
    })

    test("closed decision shows closed state", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Look for closed decision
      const closedBtn = page.locator('.pulse-feed-item[data-item-type="Decision"] button:has-text("Closed")').first()

      if ((await closedBtn.count()) === 0) {
        // No closed decisions
        test.skip()
        return
      }

      await expect(closedBtn).toBeVisible()
      await expect(closedBtn).toBeDisabled()
    })
  })

  test.describe("Commitment Actions", () => {
    test("open commitment shows join button or joined state", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const commitmentItem = page.locator('.pulse-feed-item[data-item-type="Commitment"]').first()

      if ((await commitmentItem.count()) === 0) {
        test.skip()
        return
      }

      // Should have join button, joined state, or closed state
      const joinBtn = commitmentItem.locator('button:has-text("Join")')
      const joinedBtn = commitmentItem.locator('button:has-text("Joined")')
      const closedBtn = commitmentItem.locator('button:has-text("Closed")')

      const hasJoinBtn = (await joinBtn.count()) > 0
      const hasJoinedBtn = (await joinedBtn.count()) > 0
      const hasClosedBtn = (await closedBtn.count()) > 0

      expect(hasJoinBtn || hasJoinedBtn || hasClosedBtn).toBe(true)
    })

    test("join button performs AJAX action", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const commitmentItem = page.locator('.pulse-feed-item[data-item-type="Commitment"]').first()

      if ((await commitmentItem.count()) === 0) {
        test.skip()
        return
      }

      const joinBtn = commitmentItem.locator('button:has-text("Join"):not(:has-text("Joined"))')

      if ((await joinBtn.count()) === 0) {
        // Already joined or closed
        test.skip()
        return
      }

      // Click join
      await joinBtn.click()

      // Button should change to loading or joined state
      await expect(
        commitmentItem.locator('button:has-text("Joining...")').or(
          commitmentItem.locator('button:has-text("Joined")'),
        ),
      ).toBeVisible({ timeout: 5000 })

      // Eventually should show joined
      await expect(
        commitmentItem.locator('button:has-text("Joined")'),
      ).toBeVisible({ timeout: 10000 })
    })

    test("closed commitment shows closed state", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      // Look for closed commitment
      const closedBtn = page.locator('.pulse-feed-item[data-item-type="Commitment"] button:has-text("Closed")').first()

      if ((await closedBtn.count()) === 0) {
        // No closed commitments
        test.skip()
        return
      }

      await expect(closedBtn).toBeVisible()
      await expect(closedBtn).toBeDisabled()
    })
  })

  test.describe("Heartbeat", () => {
    test("heartbeat section is visible when user has not sent heartbeat", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const heartbeatSection = page.locator(".pulse-heartbeat-section")

      // Section is only visible if user hasn't sent heartbeat yet
      if ((await heartbeatSection.count()) === 0) {
        // User already has heartbeat - section should not be visible
        test.skip()
        return
      }

      await expect(heartbeatSection).toBeVisible()

      // Should have tooltip
      const tooltip = heartbeatSection.locator(".tooltip")
      await expect(tooltip).toBeVisible()
    })

    test("heartbeat section hidden when user has already sent heartbeat", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const heartbeatSection = page.locator(".pulse-heartbeat-section")
      const feed = page.locator(".pulse-feed")

      // Check if user has NOT sent heartbeat (feed is blurred)
      // If so, skip this test as the precondition isn't met
      const feedClasses = await feed.getAttribute("class")
      if (feedClasses?.includes("no-heartbeat")) {
        // User hasn't sent heartbeat - skip this test
        test.skip()
        return
      }

      // User has sent heartbeat - verify the expected state:
      // Section should not exist when user has already sent heartbeat
      await expect(heartbeatSection).toHaveCount(0)

      // Feed should not be blurred when user has heartbeat
      await expect(feed).not.toHaveClass(/no-heartbeat/)
    })

    test("heartbeat section shows send button with tooltip", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const heartbeatSection = page.locator(".pulse-heartbeat-section")

      if ((await heartbeatSection.count()) === 0) {
        // User already has heartbeat
        test.skip()
        return
      }

      const sendBtn = heartbeatSection.locator('button:has-text("Send a Heartbeat")')

      // Should have send button with heart icon
      await expect(sendBtn).toBeVisible()
      await expect(sendBtn.locator(".octicon")).toBeVisible()

      // Message should mention access
      await expect(heartbeatSection).toContainText("to access")

      // Should have tooltip
      const tooltip = heartbeatSection.locator(".tooltip")
      await expect(tooltip).toBeVisible()
    })

    test("send heartbeat button performs AJAX action", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const heartbeatSection = page.locator(".pulse-heartbeat-section")
      const sendBtn = heartbeatSection.locator('button:has-text("Send a Heartbeat")')

      if ((await sendBtn.count()) === 0 || !(await sendBtn.isVisible())) {
        // Already has heartbeat
        test.skip()
        return
      }

      // Click send heartbeat
      await sendBtn.click()

      // Button should change to loading state
      await expect(
        heartbeatSection.locator('button:has-text("Sending Heartbeat")').or(
          heartbeatSection.locator(".pulse-heartbeat-full-heart:visible"),
        ),
      ).toBeVisible({ timeout: 5000 })

      // Eventually should show full heart (confirmed state)
      await expect(
        heartbeatSection.locator(".pulse-heartbeat-full-heart"),
      ).toBeVisible({ timeout: 10000 })

      // Send button should be hidden
      await expect(sendBtn).toBeHidden()

      // Message should update to show "sent" instead of "to access"
      await expect(heartbeatSection).toContainText("sent")
    })

    test("send heartbeat deblurs the feed", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const sendBtn = page.locator('.pulse-heartbeat-section button:has-text("Send a Heartbeat")')
      const feed = page.locator(".pulse-feed")

      if ((await sendBtn.count()) === 0 || !(await sendBtn.isVisible())) {
        // Already has heartbeat
        test.skip()
        return
      }

      // Feed should have blur class before sending heartbeat
      await expect(feed).toHaveClass(/no-heartbeat/)

      // Click send heartbeat
      await sendBtn.click()

      // Feed should no longer have blur class (wait for AJAX to complete)
      await expect(feed).not.toHaveClass(/no-heartbeat/, { timeout: 10000 })
    })

    test("heartbeat message can be dismissed after sending", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const heartbeatSection = page.locator(".pulse-heartbeat-section")

      // Section only appears if user hasn't sent heartbeat yet
      if ((await heartbeatSection.count()) === 0) {
        // User already has heartbeat - section not shown, nothing to dismiss
        test.skip()
        return
      }

      const sendBtn = heartbeatSection.locator('button:has-text("Send a Heartbeat")')
      const dismissBtn = heartbeatSection.locator(".pulse-heartbeat-dismiss")

      // Send heartbeat first
      await sendBtn.click()

      // Wait for dismiss button to appear
      await expect(dismissBtn).toBeVisible({ timeout: 10000 })

      // Click dismiss
      await dismissBtn.click()

      // Section should be hidden
      await expect(heartbeatSection).toBeHidden()
    })

    test("sidebar heartbeat count updates after sending", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const sendBtn = page.locator('.pulse-heartbeat-section button:has-text("Send a Heartbeat")')
      const sidebarCount = page.locator("#pulse-heartbeat-count-number")

      if ((await sendBtn.count()) === 0 || !(await sendBtn.isVisible())) {
        // Already has heartbeat
        test.skip()
        return
      }

      // Get initial count
      const initialCountText = await sidebarCount.textContent()
      const initialCount = parseInt(initialCountText || "0", 10)

      // Send heartbeat
      await sendBtn.click()

      // Wait for count to update (polling with expect)
      await expect(async () => {
        const newCountText = await sidebarCount.textContent()
        const newCount = parseInt(newCountText || "0", 10)
        expect(newCount).toBeGreaterThan(initialCount)
      }).toPass({ timeout: 10000 })

      // Count should have increased
      const newCountText = await sidebarCount.textContent()
      const newCount = parseInt(newCountText || "0", 10)

      expect(newCount).toBeGreaterThan(initialCount)
    })

    test("heartbeat section does not reappear after page refresh", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const heartbeatSection = page.locator(".pulse-heartbeat-section")

      // If section is not visible, user already has heartbeat
      if ((await heartbeatSection.count()) === 0) {
        // Good - already has heartbeat, verify it stays hidden after refresh
        await page.reload()
        await expect(heartbeatSection).toHaveCount(0)
        return
      }

      // Send heartbeat
      const sendBtn = heartbeatSection.locator('button:has-text("Send a Heartbeat")')
      await sendBtn.click()

      // Wait for heartbeat to be sent (dismiss button appears)
      await expect(heartbeatSection.locator(".pulse-heartbeat-dismiss")).toBeVisible({ timeout: 10000 })

      // Refresh page
      await page.reload()

      // Heartbeat section should not appear after refresh
      await expect(heartbeatSection).toHaveCount(0)
    })
  })

  test.describe("Empty State", () => {
    test("empty state shows when no activity", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const emptyState = page.locator(".pulse-feed-empty")
      const feedItems = page.locator(".pulse-feed-item")

      // If no items, should show empty state
      if ((await feedItems.count()) === 0) {
        await expect(emptyState).toBeVisible()
        await expect(emptyState).toContainText("No activity this cycle")

        // Should have create note link
        const createLink = emptyState.locator('a:has-text("Create the first note")')
        await expect(createLink).toBeVisible()
      }
    })
  })

  test.describe("Navigation", () => {
    test("view link navigates to resource", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const viewLink = page.locator(".pulse-feed-action-link").first()

      if ((await viewLink.count()) === 0) {
        test.skip()
        return
      }

      const href = await viewLink.getAttribute("href")
      await viewLink.click()

      // Should navigate to resource
      await expect(page).toHaveURL(new RegExp(href!.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")))
    })

    test("members link navigates to team page", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const membersLink = page.locator('.pulse-member-link')
      await membersLink.click()

      // Should navigate to members page
      await expect(page).toHaveURL(/\/members/)
    })

    test("new button navigates to note creation", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioHandle = await navigateToPulse(page)

      if (!studioHandle) {
        test.skip()
        return
      }

      const newButton = page.locator('a.pulse-action-btn:has-text("+ New")')
      await newButton.click()

      // Should navigate to note creation
      await expect(page).toHaveURL(/\/note/)
    })
  })
})
