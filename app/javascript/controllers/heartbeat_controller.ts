import { Controller } from "@hotwired/stimulus"

interface HeartbeatResponse {
  other_heartbeats: number
  cycle_display_name: string
}

export default class HeartbeatController extends Controller {
  static targets = [
    "sendButton",
    "sendButtonText",
    "heartbeatMessage",
    "fullHeart",
    "heartbeatsIndexLink",
    "dismissButton",
  ]

  declare readonly sendButtonTarget: HTMLElement
  declare readonly sendButtonTextTarget: HTMLElement
  declare readonly heartbeatMessageTarget: HTMLElement
  declare readonly fullHeartTarget: HTMLElement
  declare readonly heartbeatsIndexLinkTarget: HTMLElement
  declare readonly dismissButtonTarget: HTMLElement
  declare readonly hasDismissButtonTarget: boolean

  private expandingHeart: HTMLElement | null = null

  connect(): void {
    this.sendButtonTarget.addEventListener("click", this.sendHeartbeat.bind(this))
    this.expandingHeart = document.getElementById("expanding-heart")

    if (this.hasDismissButtonTarget) {
      this.dismissButtonTarget.addEventListener("click", this.dismiss.bind(this))
    }
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  sendHeartbeat(): void {
    this.animateExpandingHeart()
    const url = (this.sendButtonTarget as HTMLElement).dataset.url
    if (!url) return

    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify({}),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Network response was not ok.")
      })
      .then((responseBody: HeartbeatResponse) => {
        this.updateMessage(responseBody)
        this.showBlurred()
        this.updateSidebarHeartbeatCount(responseBody.other_heartbeats + 1)
        this.enableCycleNavigation()
        this.showDismissButton()
      })
  }

  dismiss(): void {
    const section = this.element as HTMLElement
    section.style.display = "none"
  }

  animateExpandingHeart(): void {
    if (!this.expandingHeart) return
    this.expandingHeart.style.display = "block"
    this.sendButtonTarget.style.opacity = "0.8"
    this.sendButtonTarget.style.cursor = "default"
    this.sendButtonTextTarget.textContent = "Sending Heartbeat"
    const rect = this.sendButtonTarget.getBoundingClientRect()
    this.expandingHeart.style.top = `${rect.top + window.scrollY}px`
    this.expandingHeart.style.left = `${rect.left}px`
    setTimeout(() => {
      if (!this.expandingHeart) return
      this.expandingHeart.classList.add("expanded")
      setTimeout(() => {
        if (!this.expandingHeart) return
        this.expandingHeart.style.display = "none"
      }, 1000)
    }, 1)
  }

  updateMessage(responseBody: HeartbeatResponse): void {
    const ohbs = responseBody.other_heartbeats
    const cycleName = responseBody.cycle_display_name
    this.heartbeatMessageTarget.textContent =
      `You ${ohbs > 0 ? "+ " + ohbs + " other" + (ohbs == 1 ? "" : "s") : ""} ` +
      `sent ${ohbs == 0 ? "a " : ""}heartbeat${ohbs > 0 ? "s" : ""} ${cycleName}.`
    this.fullHeartTarget.style.display = "inline"
    this.sendButtonTarget.style.display = "none"
  }

  showBlurred(): void {
    const blurs = document.querySelectorAll(
      ".blur-if-no-heartbeat.no-heartbeat, .pulse-blur-if-no-heartbeat.no-heartbeat",
    )
    blurs.forEach((b) => b.classList.remove("no-heartbeat"))
  }

  showDismissButton(): void {
    if (this.hasDismissButtonTarget) {
      this.dismissButtonTarget.style.display = "inline"
    }
  }

  updateSidebarHeartbeatCount(newCount: number): void {
    const countElement = document.getElementById("pulse-heartbeat-count-number")
    if (countElement) {
      countElement.textContent = String(newCount)
    }
  }

  enableCycleNavigation(): void {
    const disabledArrow = document.getElementById("pulse-prev-cycle-arrow")
    if (!disabledArrow) return

    const href = disabledArrow.dataset.href
    if (!href) return

    // Replace the disabled span with an enabled anchor
    const anchor = document.createElement("a")
    anchor.href = href
    anchor.className = "pulse-cycle-nav-arrow"
    anchor.title = "Previous cycle"
    anchor.innerHTML = disabledArrow.innerHTML
    disabledArrow.replaceWith(anchor)
  }
}
