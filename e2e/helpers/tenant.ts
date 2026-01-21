import { Page } from "@playwright/test"

const DEFAULT_HOSTNAME = process.env.E2E_HOSTNAME || "harmonic.local"
const DEFAULT_PORT = process.env.E2E_PORT || ""
const DEFAULT_PROTOCOL = process.env.E2E_PROTOCOL || "https"

export interface TenantOptions {
  subdomain: string
  hostname?: string
  port?: string
}

/**
 * Builds a URL for a specific tenant/subdomain
 */
export function buildTenantUrl(path: string, options: TenantOptions): string {
  const { subdomain, hostname = DEFAULT_HOSTNAME, port = DEFAULT_PORT } = options
  const portSuffix = port ? `:${port}` : ""
  const normalizedPath = path.startsWith("/") ? path : `/${path}`
  return `${DEFAULT_PROTOCOL}://${subdomain}.${hostname}${portSuffix}${normalizedPath}`
}

/**
 * Navigate to a path on a specific subdomain
 */
export async function gotoTenant(
  page: Page,
  path: string,
  subdomain: string,
): Promise<void> {
  const url = buildTenantUrl(path, { subdomain })
  await page.goto(url)
}

/**
 * Get the current subdomain from the page URL
 */
export function getCurrentSubdomain(page: Page): string {
  const url = new URL(page.url())
  const hostParts = url.hostname.split(".")

  // Handle cases like "www.harmonic.localhost" -> "www"
  // or "harmonic.localhost" -> "harmonic"
  if (hostParts.length >= 2) {
    return hostParts[0]
  }
  return hostParts[0]
}

/**
 * Extract tenant info from the current page
 */
export function getTenantInfo(page: Page): {
  subdomain: string
  hostname: string
  port: string
} {
  const url = new URL(page.url())
  const hostParts = url.hostname.split(".")
  const subdomain = hostParts[0]
  const hostname = hostParts.slice(1).join(".")

  return {
    subdomain,
    hostname: hostname || url.hostname,
    port: url.port,
  }
}
