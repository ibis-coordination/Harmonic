import { createFileRoute, Link } from "@tanstack/react-router"
import { useQuery } from "@tanstack/react-query"
import { useAppStore } from "@/stores/app"
import { StudiosService, runApiEffect } from "@/services/api"
import type { Studio } from "@/services/types"

export const Route = createFileRoute("/")({
  component: IndexComponent,
})

export function IndexComponent() {
  const { currentTenant, currentUser } = useAppStore()

  const { data: studios = [], isLoading } = useQuery<Studio[]>({
    queryKey: ["studios"],
    queryFn: () => runApiEffect(StudiosService.list()),
  })

  const domain = currentTenant.subdomain
    ? `${currentTenant.subdomain}.harmonic.local`
    : "harmonic.local"

  return (
    <div>
      <h1 className="text-3xl font-bold text-gray-900 mb-6">
        <code className="bg-gray-100 px-2 py-1 rounded">{domain}</code>
      </h1>

      <section className="mb-8">
        <h2 className="text-xl font-semibold text-gray-900 mb-4">
          Your Studios
        </h2>
        {isLoading ? (
          <p className="text-gray-500">Loading...</p>
        ) : studios.length === 0 ? (
          <p className="text-gray-500">No studios yet.</p>
        ) : (
          <ul className="space-y-2">
            {studios.map((studio) => (
              <li key={studio.id}>
                <Link
                  to="/studios/$handle"
                  params={{ handle: studio.handle }}
                  className="text-blue-600 hover:text-blue-800 hover:underline"
                >
                  {studio.name}
                </Link>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Actions</h2>
        <ul className="space-y-2">
          <li>
            <a
              href="/studios/new"
              className="text-blue-600 hover:text-blue-800 hover:underline"
            >
              New Studio
            </a>
          </li>
        </ul>
      </section>

      {currentUser && (
        <p className="mt-8 text-sm text-gray-500">
          You can switch back to the classic UI in{" "}
          <a
            href={`/u/${currentUser.handle}/settings`}
            className="text-blue-600 hover:text-blue-800"
          >
            your settings
          </a>
          .
        </p>
      )}
    </div>
  )
}
