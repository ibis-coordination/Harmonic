import { Controller } from "@hotwired/stimulus"

/**
 * Handles client-side filtering of the Pulse activity feed.
 * Allows filtering by item type (Note, Decision, Commitment) without page navigation.
 */
export default class PulseFilterController extends Controller {
  static targets = ["navItem", "feedItem", "indicator", "indicatorLabel"]

  declare readonly navItemTargets: HTMLElement[]
  declare readonly feedItemTargets: HTMLElement[]
  declare readonly indicatorTarget: HTMLElement
  declare readonly indicatorLabelTarget: HTMLElement
  declare readonly hasIndicatorTarget: boolean
  declare readonly hasIndicatorLabelTarget: boolean

  private currentFilter: string | null = null

  private static readonly filterLabels: Record<string, string> = {
    Note: "Notes",
    Decision: "Decisions",
    Commitment: "Commitments",
  }

  filter(event: Event): void {
    event.preventDefault()

    const target = event.currentTarget as HTMLElement
    const filterType = target.dataset.filterType || null

    // Toggle filter if clicking the same one
    if (this.currentFilter === filterType) {
      this.currentFilter = null
    } else {
      this.currentFilter = filterType
    }

    this.updateNavState()
    this.updateFeedVisibility()
    this.updateIndicator()
  }

  showAll(event: Event): void {
    event.preventDefault()

    this.currentFilter = null
    this.updateNavState()
    this.updateFeedVisibility()
    this.updateIndicator()
  }

  private updateNavState(): void {
    this.navItemTargets.forEach((item) => {
      const filterType = item.dataset.filterType
      if (this.currentFilter === null) {
        // When showing all, only "Activity" should be active
        item.classList.toggle("active", !filterType)
      } else {
        // When filtering, only the active filter should be highlighted
        item.classList.toggle("active", filterType === this.currentFilter)
      }
    })
  }

  private updateFeedVisibility(): void {
    this.feedItemTargets.forEach((item) => {
      const itemType = item.dataset.itemType
      if (this.currentFilter === null || itemType === this.currentFilter) {
        item.style.display = ""
      } else {
        item.style.display = "none"
      }
    })
  }

  private updateIndicator(): void {
    if (!this.hasIndicatorTarget) return

    if (this.currentFilter === null) {
      this.indicatorTarget.style.display = "none"
    } else {
      this.indicatorTarget.style.display = ""
      if (this.hasIndicatorLabelTarget) {
        const label =
          PulseFilterController.filterLabels[this.currentFilter] ||
          this.currentFilter
        this.indicatorLabelTarget.textContent = label
      }
    }
  }
}
