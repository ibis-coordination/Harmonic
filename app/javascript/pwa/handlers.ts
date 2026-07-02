// Fetch-response strategies for the service worker. The cache and fetch
// function are injected so the logic can be unit tested without
// service-worker globals.

export interface CacheLike {
  match(request: Request | string): Promise<Response | undefined>
  put(request: Request | string, response: Response): Promise<void>
}

type FetchFn = (request: Request | string) => Promise<Response>

export async function respondCacheFirst(cache: CacheLike, request: Request | string, fetchFn: FetchFn): Promise<Response> {
  const cached = await cache.match(request)
  if (cached) return cached

  const response = await fetchFn(request)
  if (response.status === 200) {
    // Best-effort: a failed write (quota, private browsing) must not turn a
    // successful fetch into a network error.
    await cache.put(request, response.clone()).catch(() => undefined)
  }
  return response
}

export async function respondNetworkFirst(
  cache: CacheLike,
  request: Request | string,
  fetchFn: FetchFn,
  offlinePath: string,
): Promise<Response> {
  try {
    return await fetchFn(request)
  } catch (error) {
    const offline = await cache.match(offlinePath)
    if (offline) return offline
    throw error
  }
}
