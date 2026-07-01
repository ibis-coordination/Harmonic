// Registers the service worker when the layout marks the feature enabled for
// the current tenant. The SW route itself serves an unregister stub when the
// flag is off, so flipping the flag off also cleans up existing installs.

export function registerServiceWorker(): void {
  if (!("serviceWorker" in navigator)) return
  if (!document.querySelector('meta[name="service-worker-enabled"]')) return

  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js").catch((error) => {
      console.warn("Service worker registration failed:", error)
    })
  })
}
