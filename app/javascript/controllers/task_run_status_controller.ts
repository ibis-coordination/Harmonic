import { Controller } from "@hotwired/stimulus"

interface StepData {
  type: string
  timestamp: string
  detail?: Record<string, unknown>
}

interface StatusResponse {
  status: string
  steps_count: number
  steps: StepData[]
  final_message?: string
  error?: string
}

/**
 * TaskRunStatusController polls for task run status changes and updates
 * the page incrementally without full page reloads.
 *
 * Usage:
 * <div data-controller="task-run-status"
 *      data-task-run-status-url-value="/ai-agents/bot/runs/123"
 *      data-task-run-status-status-value="running"
 *      data-task-run-status-steps-count-value="0">
 * </div>
 */
export default class TaskRunStatusController extends Controller<HTMLElement> {
  static values = {
    url: String,
    status: String,
    stepsCount: { type: Number, default: 0 },
    pollInterval: { type: Number, default: 3000 },
  }

  static targets = [
    "container",
    "title",
    "summary",
    "statusHeader",
    "statusMessage",
    "errorMessage",
    "stepsCount",
    "feed",
    "cancelButton",
  ]

  declare urlValue: string
  declare statusValue: string
  declare stepsCountValue: number
  declare pollIntervalValue: number

  declare readonly containerTarget: HTMLElement
  declare readonly titleTarget: HTMLElement
  declare readonly summaryTarget: HTMLElement
  declare readonly statusHeaderTarget: HTMLElement
  declare readonly statusMessageTarget: HTMLElement
  declare readonly errorMessageTarget: HTMLElement
  declare readonly stepsCountTarget: HTMLElement
  declare readonly feedTarget: HTMLElement
  declare readonly cancelButtonTarget: HTMLElement

  declare readonly hasTitleTarget: boolean
  declare readonly hasSummaryTarget: boolean
  declare readonly hasStatusHeaderTarget: boolean
  declare readonly hasStatusMessageTarget: boolean
  declare readonly hasErrorMessageTarget: boolean
  declare readonly hasStepsCountTarget: boolean
  declare readonly hasFeedTarget: boolean
  declare readonly hasCancelButtonTarget: boolean

  private pollTimer: number | null = null

  connect(): void {
    if (this.shouldPoll()) {
      // Check immediately on connect in case page loaded with stale data
      this.checkStatus()
      this.startPolling()
    }
  }

  disconnect(): void {
    this.stopPolling()
  }

  private shouldPoll(): boolean {
    return this.statusValue === "running" || this.statusValue === "queued"
  }

  private startPolling(): void {
    this.pollTimer = window.setInterval(() => {
      this.checkStatus()
    }, this.pollIntervalValue)
  }

  private stopPolling(): void {
    if (this.pollTimer !== null) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  private async checkStatus(): Promise<void> {
    try {
      const response = await fetch(this.urlValue, {
        headers: {
          Accept: "application/json",
        },
        credentials: "same-origin",
      })

      if (!response.ok) {
        return
      }

      const data: StatusResponse = await response.json()

      // Check if there are changes
      const statusChanged = data.status !== this.statusValue
      const newStepsCount = data.steps_count || 0
      const hasNewSteps = newStepsCount > this.stepsCountValue

      if (!statusChanged && !hasNewSteps) {
        return
      }

      // If status changed, update all status-related UI
      if (statusChanged) {
        this.updateStatusUI(data)
        this.statusValue = data.status
      }

      // If there are new steps, append them
      if (hasNewSteps) {
        this.appendNewSteps(data.steps, this.stepsCountValue)
        this.stepsCountValue = newStepsCount

        // Update step count display
        if (this.hasStepsCountTarget) {
          this.stepsCountTarget.textContent = String(newStepsCount)
        }
      }

      // Stop polling if task is done
      const isDone = ["completed", "failed", "cancelled"].includes(data.status)
      if (isDone) {
        this.stopPolling()
      }
    } catch {
      // Silently fail - network errors shouldn't disrupt the user
    }
  }

  private updateStatusUI(data: StatusResponse): void {
    const { status, final_message, error } = data

    // Update title
    if (this.hasTitleTarget) {
      const titleText = this.getTitleForStatus(status)
      this.titleTarget.textContent = titleText
    }

    // Update status header (icon + text)
    if (this.hasStatusHeaderTarget) {
      this.statusHeaderTarget.innerHTML = this.getStatusHeaderHTML(status)
    }

    // Update status message
    if (this.hasStatusMessageTarget) {
      if (status === "running") {
        this.statusMessageTarget.textContent = "The agent is working on this task..."
      } else if (status === "queued") {
        this.statusMessageTarget.textContent = "Waiting for agent to start..."
      } else if (final_message) {
        this.statusMessageTarget.textContent = final_message
      }
    }

    // Update error message
    if (this.hasErrorMessageTarget) {
      if (error) {
        this.errorMessageTarget.textContent = `Error: ${error}`
        this.errorMessageTarget.style.display = "block"
      } else {
        this.errorMessageTarget.style.display = "none"
      }
    }

    // Update summary box class for status coloring
    if (this.hasSummaryTarget) {
      const summaryClasses = ["pulse-notice", "pulse-alert-danger"]
      this.summaryTarget.classList.remove(...summaryClasses)
      this.summaryTarget.classList.add(this.getSummaryClass(status))
    }

    // Hide cancel button when task is done
    if (this.hasCancelButtonTarget) {
      const isDone = ["completed", "failed", "cancelled"].includes(status)
      this.cancelButtonTarget.style.display = isDone ? "none" : ""
    }
  }

  private getTitleForStatus(status: string): string {
    switch (status) {
      case "completed":
        return "Success"
      case "failed":
        return "Failed"
      case "running":
        return "Running"
      case "queued":
        return "Queued"
      case "cancelled":
        return "Cancelled"
      default:
        return status.charAt(0).toUpperCase() + status.slice(1)
    }
  }

  private getStatusHeaderHTML(status: string): string {
    switch (status) {
      case "completed":
        return `<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" style="color: var(--color-success-fg);"><path fill-rule="evenodd" d="M8 16A8 8 0 108 0a8 8 0 000 16zm3.78-9.72a.75.75 0 00-1.06-1.06L6.75 9.19 5.28 7.72a.75.75 0 00-1.06 1.06l2 2a.75.75 0 001.06 0l4.5-4.5z"></path></svg>
        <strong>Task Completed</strong>`
      case "failed":
        return `<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" style="color: var(--color-danger-fg);"><path fill-rule="evenodd" d="M2.343 13.657A8 8 0 1113.657 2.343 8 8 0 012.343 13.657zM6.03 4.97a.75.75 0 00-1.06 1.06L6.94 8 4.97 9.97a.75.75 0 101.06 1.06L8 9.06l1.97 1.97a.75.75 0 101.06-1.06L9.06 8l1.97-1.97a.75.75 0 10-1.06-1.06L8 6.94 6.03 4.97z"></path></svg>
        <strong>Task Failed</strong>`
      case "running":
        return `<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" style="color: var(--color-accent-fg);"><path fill-rule="evenodd" d="M8 2.5a5.487 5.487 0 00-4.131 1.869l1.204 1.204A.25.25 0 014.896 6H1.25A.25.25 0 011 5.75V2.104a.25.25 0 01.427-.177l1.38 1.38A7.001 7.001 0 0114.95 7.16a.75.75 0 11-1.49.178A5.501 5.501 0 008 2.5zM1.705 8.005a.75.75 0 01.834.656 5.501 5.501 0 009.592 2.97l-1.204-1.204a.25.25 0 01.177-.427h3.646a.25.25 0 01.25.25v3.646a.25.25 0 01-.427.177l-1.38-1.38A7.001 7.001 0 011.05 8.84a.75.75 0 01.656-.834z"></path></svg>
        <strong>Task Running</strong>`
      case "queued":
        return `<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" style="color: var(--color-attention-fg);"><path fill-rule="evenodd" d="M1.5 8a6.5 6.5 0 1113 0 6.5 6.5 0 01-13 0zM8 0a8 8 0 100 16A8 8 0 008 0zm.5 4.75a.75.75 0 00-1.5 0v3.5a.75.75 0 00.471.696l2.5 1a.75.75 0 00.557-1.392L8.5 7.742V4.75z"></path></svg>
        <strong>Task Queued</strong>`
      case "cancelled":
        return `<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" style="color: var(--color-danger-fg);"><path fill-rule="evenodd" d="M2.343 13.657A8 8 0 1113.657 2.343 8 8 0 012.343 13.657zM6.03 4.97a.75.75 0 00-1.06 1.06L6.94 8 4.97 9.97a.75.75 0 101.06 1.06L8 9.06l1.97 1.97a.75.75 0 101.06-1.06L9.06 8l1.97-1.97a.75.75 0 10-1.06-1.06L8 6.94 6.03 4.97z"></path></svg>
        <strong>Task Cancelled</strong>`
      default:
        return `<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path fill-rule="evenodd" d="M8 1.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13zM0 8a8 8 0 1116 0A8 8 0 010 8zm9 3a1 1 0 11-2 0 1 1 0 012 0zm-.25-6.25a.75.75 0 00-1.5 0v3.5a.75.75 0 001.5 0v-3.5z"></path></svg>
        <strong>${status.charAt(0).toUpperCase() + status.slice(1)}</strong>`
    }
  }

  private getSummaryClass(status: string): string {
    if (status === "failed" || status === "cancelled") {
      return "pulse-alert-danger"
    }
    return "pulse-notice"
  }

  private appendNewSteps(steps: StepData[], startIndex: number): void {
    if (!this.hasFeedTarget) {
      return
    }

    const newSteps = steps.slice(startIndex)
    for (let i = 0; i < newSteps.length; i++) {
      const step = newSteps[i]
      const stepIndex = startIndex + i
      const stepHTML = this.renderStep(step, stepIndex)
      this.feedTarget.insertAdjacentHTML("beforeend", stepHTML)
    }
  }

  private renderStep(step: StepData, index: number): string {
    const detail = step.detail || {}
    const isClosed = step.type === "done" ? " pulse-feed-item-closed" : ""
    const timestamp = new Date(step.timestamp).toLocaleTimeString("en-US", {
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    })

    const icon = this.getStepIcon(step.type)
    const body = this.renderStepBody(step.type, detail, index)

    return `
      <article class="pulse-feed-item${isClosed}">
        <div class="pulse-feed-item-header">
          <div class="pulse-feed-item-type">
            ${icon}
            ${step.type.toUpperCase()}
          </div>
          <div class="pulse-feed-item-meta">
            <span>Step ${index + 1}</span>
            <span>&middot;</span>
            <span>${timestamp}</span>
          </div>
        </div>
        <div class="pulse-feed-item-body">
          ${body}
        </div>
      </article>
    `
  }

  private getStepIcon(type: string): string {
    const icons: Record<string, string> = {
      navigate:
        '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8.22 2.97a.75.75 0 011.06 0l4.25 4.25a.75.75 0 010 1.06l-4.25 4.25a.75.75 0 01-1.06-1.06l2.97-2.97H3.75a.75.75 0 010-1.5h7.44L8.22 4.03a.75.75 0 010-1.06z"></path></svg>',
      execute:
        '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M1.5 8a6.5 6.5 0 1113 0 6.5 6.5 0 01-13 0zM8 0a8 8 0 100 16A8 8 0 008 0zM6.379 5.227A.25.25 0 006 5.442v5.117a.25.25 0 00.379.214l4.264-2.559a.25.25 0 000-.428L6.379 5.227z"></path></svg>',
      think:
        '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 01-1.484.211c-.04-.282-.163-.547-.37-.847a8.695 8.695 0 00-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.542.681-.208.3-.33.565-.37.847a.75.75 0 01-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75zM6 15.25a.75.75 0 01.75-.75h2.5a.75.75 0 010 1.5h-2.5a.75.75 0 01-.75-.75zM5.75 12a.75.75 0 000 1.5h4.5a.75.75 0 000-1.5h-4.5z"></path></svg>',
      done: '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M13.78 4.22a.75.75 0 010 1.06l-7.25 7.25a.75.75 0 01-1.06 0L2.22 9.28a.75.75 0 011.06-1.06L6 10.94l6.72-6.72a.75.75 0 011.06 0z"></path></svg>',
      error:
        '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8.22 1.754a.25.25 0 00-.44 0L1.698 13.132a.25.25 0 00.22.368h12.164a.25.25 0 00.22-.368L8.22 1.754zm-1.763-.707c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0114.082 15H1.918a1.75 1.75 0 01-1.543-2.575L6.457 1.047zM9 11a1 1 0 11-2 0 1 1 0 012 0zm-.25-5.25a.75.75 0 00-1.5 0v2.5a.75.75 0 001.5 0v-2.5z"></path></svg>',
      scratchpad_update:
        '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v12.5A1.75 1.75 0 0114.25 16H1.75A1.75 1.75 0 010 14.25V1.75zm1.75-.25a.25.25 0 00-.25.25v12.5c0 .138.112.25.25.25h12.5a.25.25 0 00.25-.25V1.75a.25.25 0 00-.25-.25H1.75zM3.5 3.5A.75.75 0 014.25 2.75h7.5a.75.75 0 010 1.5h-7.5A.75.75 0 013.5 3.5zm0 4A.75.75 0 014.25 6.75h7.5a.75.75 0 010 1.5h-7.5A.75.75 0 013.5 7.5zm0 4a.75.75 0 01.75-.75h4a.75.75 0 010 1.5h-4a.75.75 0 01-.75-.75z"></path></svg>',
      scratchpad_update_failed:
        '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8.22 1.754a.25.25 0 00-.44 0L1.698 13.132a.25.25 0 00.22.368h12.164a.25.25 0 00.22-.368L8.22 1.754zm-1.763-.707c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0114.082 15H1.918a1.75 1.75 0 01-1.543-2.575L6.457 1.047zM9 11a1 1 0 11-2 0 1 1 0 012 0zm-.25-5.25a.75.75 0 00-1.5 0v2.5a.75.75 0 001.5 0v-2.5z"></path></svg>',
      security_warning:
        '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8.533.133a1.75 1.75 0 00-1.066 0l-5.25 1.68A1.75 1.75 0 001 3.48V7c0 1.566.32 3.182 1.303 4.682.983 1.498 2.585 2.813 5.032 3.855a1.7 1.7 0 001.33 0c2.447-1.042 4.049-2.357 5.032-3.855C14.68 10.182 15 8.566 15 7V3.48a1.75 1.75 0 00-1.217-1.667L8.533.133zm-.61 1.429a.25.25 0 01.153 0l5.25 1.68a.25.25 0 01.174.238V7c0 1.358-.275 2.666-1.057 3.86-.784 1.194-2.121 2.34-4.366 3.297a.2.2 0 01-.154 0c-2.245-.956-3.582-2.104-4.366-3.298C2.775 9.666 2.5 8.36 2.5 7V3.48a.25.25 0 01.174-.238l5.25-1.68zM9.5 6.5a1.5 1.5 0 01-.75 1.3v1.45a.75.75 0 01-1.5 0V7.8A1.5 1.5 0 119.5 6.5z"></path></svg>',
    }
    return (
      icons[type] ||
      '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8 4a4 4 0 100 8 4 4 0 000-8z"></path></svg>'
    )
  }

  private renderStepBody(type: string, detail: Record<string, unknown>, index: number): string {
    switch (type) {
      case "navigate":
        return this.renderNavigateStep(detail)
      case "execute":
        return this.renderExecuteStep(detail)
      case "think":
        return this.renderThinkStep(detail, index)
      case "done":
        return this.renderDoneStep(detail)
      case "error":
        return this.renderErrorStep(detail)
      case "scratchpad_update":
        return this.renderScratchpadUpdateStep(detail)
      case "scratchpad_update_failed":
        return this.renderScratchpadUpdateFailedStep(detail)
      case "security_warning":
        return this.renderSecurityWarningStep(detail)
      default:
        return ""
    }
  }

  private renderNavigateStep(detail: Record<string, unknown>): string {
    const path = detail.path || ""
    const availableActions = detail.available_actions as string[] | undefined
    const contentPreview = detail.content_preview as string | undefined

    let html = `<div class="pulse-feed-item-title">Navigated to: <code class="pulse-code">${this.escapeHtml(String(path))}</code></div>`

    if (availableActions && availableActions.length > 0) {
      html += `<p class="pulse-muted" style="margin: 8px 0 0 0;">Available actions: ${this.escapeHtml(availableActions.join(", "))}</p>`
    }

    if (contentPreview) {
      html += this.renderAccordion("View page content", contentPreview)
    }

    return html
  }

  private renderExecuteStep(detail: Record<string, unknown>): string {
    const action = detail.action || ""
    const success = detail.success
    const params = detail.params as Record<string, unknown> | undefined
    const error = detail.error as string | undefined
    const contentPreview = detail.content_preview as string | undefined

    const statusIcon =
      success !== false
        ? '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14" style="color: var(--color-success-fg);"><path fill-rule="evenodd" d="M8 16A8 8 0 108 0a8 8 0 000 16zm3.78-9.72a.75.75 0 00-1.06-1.06L6.75 9.19 5.28 7.72a.75.75 0 00-1.06 1.06l2 2a.75.75 0 001.06 0l4.5-4.5z"></path></svg>'
        : '<svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14" style="color: var(--color-danger-fg);"><path fill-rule="evenodd" d="M2.343 13.657A8 8 0 1113.657 2.343 8 8 0 012.343 13.657zM6.03 4.97a.75.75 0 00-1.06 1.06L6.94 8 4.97 9.97a.75.75 0 101.06 1.06L8 9.06l1.97 1.97a.75.75 0 101.06-1.06L9.06 8l1.97-1.97a.75.75 0 10-1.06-1.06L8 6.94 6.03 4.97z"></path></svg>'

    let html = `<div class="pulse-feed-item-title">Executed: <code class="pulse-code">${this.escapeHtml(String(action))}</code> ${statusIcon}</div>`

    if (params && Object.keys(params).length > 0) {
      html += `<p class="pulse-muted" style="margin: 8px 0 0 0;">Params: <code class="pulse-code" style="font-size: 11px;">${this.escapeHtml(JSON.stringify(params))}</code></p>`
    }

    if (error) {
      html += `<p style="color: var(--color-danger-fg); margin: 8px 0 0 0;">Error: ${this.escapeHtml(error)}</p>`
    }

    if (contentPreview) {
      html += this.renderAccordion("View result", contentPreview)
    }

    return html
  }

  private renderThinkStep(detail: Record<string, unknown>, _index: number): string {
    const stepNumber = (detail.step_number as number) || 0
    const llmError = detail.llm_error as string | undefined
    const responsePreview = detail.response_preview as string | undefined

    let html = `<div class="pulse-feed-item-content">LLM reasoning (step ${stepNumber + 1})`

    if (llmError) {
      html += ` <span style="color: var(--color-danger-fg); margin-left: 8px;">
        <svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8.22 1.754a.25.25 0 00-.44 0L1.698 13.132a.25.25 0 00.22.368h12.164a.25.25 0 00.22-.368L8.22 1.754zm-1.763-.707c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0114.082 15H1.918a1.75 1.75 0 01-1.543-2.575L6.457 1.047zM9 11a1 1 0 11-2 0 1 1 0 012 0zm-.25-5.25a.75.75 0 00-1.5 0v2.5a.75.75 0 001.5 0v-2.5z"></path></svg> LLM Error
      </span>`
    }

    html += `</div>`

    if (llmError) {
      html += `<p style="color: var(--color-danger-fg); margin: 8px 0 0 0; font-size: 13px;">${this.escapeHtml(llmError)}</p>`
    }

    if (responsePreview) {
      // Strip trailing JSON action from response preview (mimicking server helper)
      const cleanedResponse = this.stripTrailingJsonAction(responsePreview)
      html += this.renderAccordion(
        "View LLM response",
        cleanedResponse || "[No response content]",
        !cleanedResponse
      )
    } else {
      html += this.renderAccordion("View LLM response", "[No response content]", true)
    }

    return html
  }

  private renderDoneStep(detail: Record<string, unknown>): string {
    const message = detail.message || ""
    return `<div class="pulse-feed-item-content" style="color: var(--color-success-fg);">${this.escapeHtml(String(message))}</div>`
  }

  private renderErrorStep(detail: Record<string, unknown>): string {
    const message = detail.message || ""
    const backtrace = detail.backtrace as string[] | undefined

    let html = `<div class="pulse-feed-item-content" style="color: var(--color-danger-fg);">${this.escapeHtml(String(message))}</div>`

    if (backtrace && backtrace.length > 0) {
      html += this.renderAccordion(
        "View backtrace",
        backtrace.join("\n"),
        false,
        "color: var(--color-danger-fg);"
      )
    }

    return html
  }

  private renderScratchpadUpdateStep(detail: Record<string, unknown>): string {
    const content = detail.content as string | undefined

    let html = `<div class="pulse-feed-item-content" style="color: var(--color-success-fg);">
      <svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v12.5A1.75 1.75 0 0114.25 16H1.75A1.75 1.75 0 010 14.25V1.75zm1.75-.25a.25.25 0 00-.25.25v12.5c0 .138.112.25.25.25h12.5a.25.25 0 00.25-.25V1.75a.25.25 0 00-.25-.25H1.75zM3.5 3.5A.75.75 0 014.25 2.75h7.5a.75.75 0 010 1.5h-7.5A.75.75 0 013.5 3.5zm0 4A.75.75 0 014.25 6.75h7.5a.75.75 0 010 1.5h-7.5A.75.75 0 013.5 7.5zm0 4a.75.75 0 01.75-.75h4a.75.75 0 010 1.5h-4a.75.75 0 01-.75-.75z"></path></svg> Scratchpad updated
    </div>`

    if (content) {
      html += this.renderAccordion("View scratchpad content", content)
    }

    return html
  }

  private renderScratchpadUpdateFailedStep(detail: Record<string, unknown>): string {
    const error = detail.error || ""
    return `
      <div class="pulse-feed-item-content" style="color: var(--color-attention-fg);">
        <svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8.22 1.754a.25.25 0 00-.44 0L1.698 13.132a.25.25 0 00.22.368h12.164a.25.25 0 00.22-.368L8.22 1.754zm-1.763-.707c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0114.082 15H1.918a1.75 1.75 0 01-1.543-2.575L6.457 1.047zM9 11a1 1 0 11-2 0 1 1 0 012 0zm-.25-5.25a.75.75 0 00-1.5 0v2.5a.75.75 0 001.5 0v-2.5z"></path></svg> Scratchpad update failed
      </div>
      <p class="pulse-muted" style="margin: 8px 0 0 0;">${this.escapeHtml(String(error))}</p>
    `
  }

  private renderSecurityWarningStep(detail: Record<string, unknown>): string {
    const warningType = detail.type || ""
    const reasons = detail.reasons as string[] | undefined

    let html = `
      <div class="pulse-feed-item-content" style="color: var(--color-attention-fg);">
        <svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M8.533.133a1.75 1.75 0 00-1.066 0l-5.25 1.68A1.75 1.75 0 001 3.48V7c0 1.566.32 3.182 1.303 4.682.983 1.498 2.585 2.813 5.032 3.855a1.7 1.7 0 001.33 0c2.447-1.042 4.049-2.357 5.032-3.855C14.68 10.182 15 8.566 15 7V3.48a1.75 1.75 0 00-1.217-1.667L8.533.133zm-.61 1.429a.25.25 0 01.153 0l5.25 1.68a.25.25 0 01.174.238V7c0 1.358-.275 2.666-1.057 3.86-.784 1.194-2.121 2.34-4.366 3.297a.2.2 0 01-.154 0c-2.245-.956-3.582-2.104-4.366-3.298C2.775 9.666 2.5 8.36 2.5 7V3.48a.25.25 0 01.174-.238l5.25-1.68zM9.5 6.5a1.5 1.5 0 01-.75 1.3v1.45a.75.75 0 01-1.5 0V7.8A1.5 1.5 0 119.5 6.5z"></path></svg> Security Warning: ${this.escapeHtml(String(warningType))}
      </div>
    `

    if (reasons && reasons.length > 0) {
      html += `<p class="pulse-muted" style="margin: 8px 0 0 0;">Reasons: ${this.escapeHtml(reasons.join(", "))}</p>`
    }

    return html
  }

  private renderAccordion(
    title: string,
    content: string,
    isItalic: boolean = false,
    extraStyle: string = ""
  ): string {
    const style = isItalic ? "font-style: italic;" : ""
    const combinedStyle = `${style}${extraStyle}`.trim()
    return `
      <details class="pulse-accordion" style="margin-top: 12px;">
        <summary class="pulse-accordion-header">
          <span class="pulse-accordion-title">${this.escapeHtml(title)}</span>
          <span class="pulse-accordion-icon"><svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="14" height="14"><path fill-rule="evenodd" d="M6.22 3.22a.75.75 0 011.06 0l4.25 4.25a.75.75 0 010 1.06l-4.25 4.25a.75.75 0 01-1.06-1.06L9.94 8 6.22 4.28a.75.75 0 010-1.06z"></path></svg></span>
        </summary>
        <div class="pulse-accordion-content">
          <pre style="font-size: 12px; white-space: pre-wrap; margin: 0;${combinedStyle ? " " + combinedStyle : ""}">${this.escapeHtml(content)}</pre>
        </div>
      </details>
    `
  }

  private stripTrailingJsonAction(text: string): string {
    // Match trailing JSON that looks like an action (has "action" key)
    const jsonPattern = /\s*\{[\s\S]*"action"[\s\S]*\}\s*$/
    return text.replace(jsonPattern, "").trim()
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
