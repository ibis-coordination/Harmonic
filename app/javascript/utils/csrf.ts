/**
 * CSRF token utility for making authenticated requests from Stimulus controllers.
 *
 * Usage:
 *   import { getCsrfToken, fetchWithCsrf } from "../utils/csrf"
 *
 *   // Get just the token
 *   const token = getCsrfToken()
 *
 *   // Or use the helper for POST/PUT/DELETE requests
 *   const response = await fetchWithCsrf("/api/endpoint", {
 *     method: "POST",
 *     body: JSON.stringify({ data: "value" }),
 *   })
 */

/**
 * Get the CSRF token from the meta tag
 */
export function getCsrfToken(): string {
  const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
  return meta?.content ?? ""
}

/**
 * Default headers for JSON API requests with CSRF token
 */
export function getDefaultHeaders(): HeadersInit {
  return {
    "Content-Type": "application/json",
    "X-CSRF-Token": getCsrfToken(),
  }
}

/**
 * Fetch wrapper that automatically includes CSRF token and Content-Type headers.
 * Use this for POST, PUT, PATCH, DELETE requests.
 */
export async function fetchWithCsrf(
  url: string,
  options: RequestInit = {}
): Promise<Response> {
  const headers = {
    ...getDefaultHeaders(),
    ...(options.headers || {}),
  }

  return fetch(url, {
    ...options,
    headers,
  })
}
