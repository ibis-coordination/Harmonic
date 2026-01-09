// Triggers a "poll" event on the document at regular intervals
// Controllers can listen for this event to refresh their data

declare global {
  interface Window {
    pausePolling?: boolean
  }
}

const POLLING_INTERVAL = 5 * 1000
let currentTimeout: ReturnType<typeof setTimeout> | null = null

const triggerPolling = (): void => {
  if (document.hidden || document.visibilityState === "hidden" || window.pausePolling) {
    // noop
  } else {
    const event = new Event("poll")
    document.dispatchEvent(event)
    if (currentTimeout) {
      clearTimeout(currentTimeout)
    }
    currentTimeout = setTimeout(triggerPolling, POLLING_INTERVAL)
  }
}

triggerPolling()
document.addEventListener("visibilitychange", triggerPolling)
