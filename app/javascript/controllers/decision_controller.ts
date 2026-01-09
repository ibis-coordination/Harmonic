import { Controller } from "@hotwired/stimulus"

export default class DecisionController extends Controller {
  static targets = ["input", "list", "optionsSection"]

  declare readonly inputTarget: HTMLInputElement
  declare readonly listTarget: HTMLElement
  declare readonly optionsSectionTarget: HTMLElement

  private refreshing = false
  private updatingApprovals = false
  private lastApprovalUpdate = ""
  private previousOptionsListHtml = ""

  initialize(): void {
    document.addEventListener("poll", this.refreshOptions.bind(this))
  }

  add(event: Event): void {
    event.preventDefault()
    const input = this.inputTarget.value.trim()
    if (input.length > 0) {
      this.createOption(input)
        .then((response) => response.text())
        .then((html) => {
          this.listTarget.innerHTML = html
          this.inputTarget.value = ""
        })
        .catch((error) => {
          console.error("Error creating option:", error)
        })
    }
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  get decisionIsClosed(): boolean {
    if (!this.optionsSectionTarget.dataset.deadline) return false
    try {
      const deadlineDate = new Date(this.optionsSectionTarget.dataset.deadline)
      const now = new Date()
      return now > deadlineDate
    } catch (error) {
      console.error("Error determining if decision is closed:", error)
      return false
    }
  }

  async createOption(title: string): Promise<Response> {
    const url = this.optionsSectionTarget.dataset.url
    if (!url) {
      throw new Error("No URL specified for creating option")
    }

    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify({ title }),
    })

    if (!response.ok) {
      throw new Error(`API request failed with status ${response.status}`)
    }
    const ddu = new Event("decisionDataUpdated")
    document.dispatchEvent(ddu)
    return response
  }

  nextApprovalState(approved: boolean, stars: boolean): [boolean, boolean] {
    if (stars) {
      return [false, false]
    } else if (approved) {
      return [true, true]
    } else {
      return [true, false]
    }
  }

  async toggleApprovalValues(event: Event): Promise<void> {
    const studioHandle = window.location.pathname.startsWith("/studios/")
      ? window.location.pathname.split("/")[2]
      : null
    const urlPrefix = studioHandle ? `/studios/${studioHandle}` : ""
    const decisionId = this.inputTarget.dataset.decisionId

    const target = event.target as HTMLElement
    const optionItem = target.closest(".option-item") as HTMLElement | null
    if (!optionItem) return

    const checkbox = optionItem.querySelector("input.approval-button") as HTMLInputElement | null
    const starButton = optionItem.querySelector("input.star-button") as HTMLInputElement | null
    if (!checkbox || !starButton) return

    const isToggleClick = target === checkbox || target === starButton

    const optionId = optionItem.dataset.optionId
    let approved = checkbox.checked
    let stars = starButton.checked

    if (!isToggleClick) {
      ;[approved, stars] = this.nextApprovalState(approved, stars)
      checkbox.checked = approved
      starButton.checked = stars
    }

    this.updatingApprovals = true
    await fetch(`${urlPrefix}/api/v1/decisions/${decisionId}/options/${optionId}/approvals`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify({ value: approved, stars }),
    })
    this.updatingApprovals = false
    this.lastApprovalUpdate = new Date().toString()
    const ddu = new Event("decisionDataUpdated")
    document.dispatchEvent(ddu)
  }

  async cycleApprovalState(event: Event): Promise<void> {
    const target = event.target as HTMLElement
    if (target.tagName === "A") return
    event.preventDefault()
    return this.toggleApprovalValues(event)
  }

  async refreshOptions(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing || this.updatingApprovals) return
    this.refreshing = true

    const url = this.optionsSectionTarget.dataset.url
    if (!url) {
      this.refreshing = false
      return
    }

    const lastApprovalUpdateBeforeRefresh = this.lastApprovalUpdate

    try {
      const response = await fetch(url, {
        method: "GET",
        headers: {
          "X-CSRF-Token": this.csrfToken,
        },
      })

      const refreshIsStale =
        this.updatingApprovals || this.lastApprovalUpdate !== lastApprovalUpdateBeforeRefresh

      if (refreshIsStale) {
        // Skip this stale refresh
      } else if (response.ok) {
        const html = await response.text()
        if (html !== this.previousOptionsListHtml) {
          this.listTarget.innerHTML = html
          this.previousOptionsListHtml = html
        } else if (this.decisionIsClosed) {
          this.hideOptions()
        }
      } else {
        console.error("Error refreshing options:", response)
      }
    } finally {
      this.refreshing = false
    }
  }

  hideOptions(): void {
    this.optionsSectionTarget.style.display = "none"
  }
}
