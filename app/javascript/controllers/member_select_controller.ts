import { Controller } from "@hotwired/stimulus"

interface UserResult {
  id: string
  handle: string
  display_name: string
  avatar_url: string | null
}

/**
 * MemberSelectController provides a searchable member selector with profile pics.
 *
 * Usage:
 * <div data-controller="member-select"
 *      data-member-select-collective-path-value="/collectives/my-collective"
 *      data-member-select-field-name-value="decision[decision_maker_id]"
 *      data-member-select-selected-id-value="user-uuid-here"
 *      data-member-select-required-value="true">
 *   <input type="hidden" data-member-select-target="hiddenInput">
 *   <div data-member-select-target="display"></div>
 *   <div data-member-select-target="dropdown" class="mention-dropdown"></div>
 * </div>
 */
export default class MemberSelectController extends Controller<HTMLElement> {
  static targets = ["hiddenInput", "searchInput", "display", "dropdown", "results"]
  static values = {
    collectivePath: { type: String, default: "" },
    fieldName: { type: String, default: "" },
    selectedId: { type: String, default: "" },
    selectedName: { type: String, default: "" },
    selectedHandle: { type: String, default: "" },
    selectedAvatarUrl: { type: String, default: "" },
    required: { type: Boolean, default: false },
  }

  declare readonly hiddenInputTarget: HTMLInputElement
  declare readonly searchInputTarget: HTMLInputElement
  declare readonly displayTarget: HTMLElement
  declare readonly dropdownTarget: HTMLElement
  declare readonly resultsTarget: HTMLElement
  declare readonly hasSearchInputTarget: boolean
  declare readonly hasResultsTarget: boolean

  declare collectivePathValue: string
  declare fieldNameValue: string
  declare selectedIdValue: string
  declare selectedNameValue: string
  declare selectedHandleValue: string
  declare selectedAvatarUrlValue: string
  declare requiredValue: boolean

  private cachedUsers: UserResult[] = []
  private results: UserResult[] = []
  private selectedIndex = 0
  private isOpen = false
  private searchTimeout: number | null = null
  private selectedUser: UserResult | null = null

  connect(): void {
    this.hiddenInputTarget.name = this.fieldNameValue
    this.hiddenInputTarget.value = this.selectedIdValue
    if (this.requiredValue) {
      this.hiddenInputTarget.required = true
    }
    // If pre-selected user data is provided, render immediately
    if (this.selectedIdValue && this.selectedNameValue) {
      this.selectedUser = {
        id: this.selectedIdValue,
        display_name: this.selectedNameValue,
        handle: this.selectedHandleValue,
        avatar_url: this.selectedAvatarUrlValue || null,
      }
    }
    this.renderDisplay()
    this.fetchAllMembers()
  }

  private async fetchAllMembers(): Promise<void> {
    try {
      const basePath = this.collectivePathValue || ""
      const url = `${basePath}/autocomplete/users?q=`
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      })
      if (response.ok) {
        this.cachedUsers = await response.json()
        // Ensure selected user is in the cache for search results
        if (this.selectedUser && !this.cachedUsers.find((u) => u.id === this.selectedUser!.id)) {
          this.cachedUsers.unshift(this.selectedUser)
        }
      }
    } catch {
      // Silently fail — will retry on search
    }
  }

  search(): void {
    if (this.searchTimeout) clearTimeout(this.searchTimeout)
    this.searchTimeout = window.setTimeout(() => {
      const query = this.hasSearchInputTarget ? this.searchInputTarget.value.toLowerCase().trim() : ""
      if (query === "") {
        this.results = this.cachedUsers.slice(0, 20)
      } else {
        this.results = this.cachedUsers.filter(
          (u) => u.display_name.toLowerCase().includes(query) || u.handle.toLowerCase().includes(query)
        )
      }
      this.selectedIndex = 0
      this.renderResults()
      this.open()
    }, 50)
  }

  handleKeydown(event: KeyboardEvent): void {
    if (!this.isOpen) {
      if (event.key === "ArrowDown" || event.key === "Enter") {
        event.preventDefault()
        this.search()
      }
      return
    }

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.selectedIndex = (this.selectedIndex + 1) % this.results.length
        this.renderResults()
        break
      case "ArrowUp":
        event.preventDefault()
        this.selectedIndex = (this.selectedIndex - 1 + this.results.length) % this.results.length
        this.renderResults()
        break
      case "Enter":
        event.preventDefault()
        this.selectResult(this.selectedIndex)
        break
      case "Escape":
        this.close()
        break
    }
  }

  clickResult(event: Event): void {
    const target = (event.target as HTMLElement).closest("[data-index]") as HTMLElement
    if (!target) return
    const index = parseInt(target.dataset.index ?? "0", 10)
    this.selectResult(index)
  }

  clear(): void {
    this.selectedUser = null
    this.hiddenInputTarget.value = ""
    this.renderDisplay()
  }

  openDropdown(): void {
    // Render the full dropdown structure once
    this.dropdownTarget.innerHTML = `
      <input type="text" class="mention-search-input" placeholder="Search members..."
             data-member-select-target="searchInput"
             data-action="input->member-select#search keydown->member-select#handleKeydown"
             style="width:100%;padding:8px;border:none;border-bottom:1px solid var(--color-border-default);outline:none;font-size:14px;box-sizing:border-box;" />
      <div data-member-select-target="results"></div>
    `
    this.results = this.cachedUsers.slice(0, 20)
    this.selectedIndex = 0
    this.renderResults()
    this.open()
    requestAnimationFrame(() => {
      if (this.hasSearchInputTarget) {
        this.searchInputTarget.focus()
      }
    })
  }

  private selectResult(index: number): void {
    if (index < 0 || index >= this.results.length) return
    this.selectedUser = this.results[index]
    this.hiddenInputTarget.value = this.selectedUser.id
    this.close()
    this.renderDisplay()
  }

  private renderDisplay(): void {
    if (this.selectedUser) {
      const u = this.selectedUser
      const avatar = u.avatar_url
        ? `<img src="${u.avatar_url}" alt="" style="width:20px;height:20px;border-radius:50%;" />`
        : `<span class="mention-avatar" style="width:20px;height:20px;font-size:10px;">${this.getInitials(u.display_name)}</span>`
      this.displayTarget.innerHTML = `
        <div style="display:flex;align-items:center;gap:8px;padding:6px 10px;border:1px solid var(--color-border-default);cursor:pointer;"
             data-action="click->member-select#openDropdown">
          ${avatar}
          <span style="flex:1;"><strong>${this.escapeHtml(u.display_name)}</strong> <span style="color:var(--color-fg-muted);">@${this.escapeHtml(u.handle)}</span></span>
          <span style="color:var(--color-fg-muted);font-size:12px;">Change</span>
        </div>
      `
    } else {
      this.displayTarget.innerHTML = `
        <button type="button" class="pulse-action-btn-secondary" style="width:100%;text-align:left;"
                data-action="click->member-select#openDropdown">
          Select a member...
        </button>
      `
    }
  }

  private renderResults(): void {
    if (!this.hasResultsTarget) return

    if (this.results.length === 0) {
      this.resultsTarget.innerHTML = `<div style="padding:8px;color:var(--color-fg-muted);">No members found</div>`
    } else {
      this.resultsTarget.innerHTML = this.results
        .map(
          (user, index) => `
          <div class="mention-item ${index === this.selectedIndex ? "mention-item-selected" : ""}"
               data-index="${index}"
               data-action="click->member-select#clickResult">
            <span class="mention-avatar">
              ${user.avatar_url ? `<img src="${user.avatar_url}" alt="" />` : this.getInitials(user.display_name)}
            </span>
            <span class="mention-info">
              <span class="mention-display-name">${this.escapeHtml(user.display_name)}</span>
              <span class="mention-handle">@${this.escapeHtml(user.handle)}</span>
            </span>
          </div>
        `
        )
        .join("")
    }
  }

  private open(): void {
    this.isOpen = true
    this.dropdownTarget.style.display = ""
    // Add click-outside listener
    document.addEventListener("click", this.handleClickOutside)
  }

  private close(): void {
    this.isOpen = false
    this.dropdownTarget.style.display = "none"
    document.removeEventListener("click", this.handleClickOutside)
  }

  private handleClickOutside = (event: Event): void => {
    if (!this.element.contains(event.target as Node)) {
      this.close()
    }
  }

  private getInitials(name: string): string {
    const parts = name.split(/[\s\-_]+/)
    if (parts.length >= 2) {
      return `${parts[0]?.[0] ?? ""}${parts[1]?.[0] ?? ""}`.toUpperCase()
    }
    return (name.slice(0, 2) || "?").toUpperCase()
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
