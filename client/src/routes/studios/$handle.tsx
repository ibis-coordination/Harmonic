import { createFileRoute, Outlet, Link } from "@tanstack/react-router"

export const Route = createFileRoute("/studios/$handle")({
  component: StudioLayout,
})

function StudioLayout() {
  const { handle } = Route.useParams()

  return (
    <div>
      <nav className="mb-6 border-b border-gray-200 pb-4">
        <ul className="flex gap-6">
          <li>
            <Link
              to="/studios/$handle"
              params={{ handle }}
              className="text-gray-600 hover:text-gray-900 [&.active]:text-blue-600 [&.active]:font-medium"
              activeOptions={{ exact: true }}
            >
              Overview
            </Link>
          </li>
          <li>
            <Link
              to="/studios/$handle/cycles/today"
              params={{ handle }}
              className="text-gray-600 hover:text-gray-900 [&.active]:text-blue-600 [&.active]:font-medium"
            >
              Today
            </Link>
          </li>
          <li>
            <Link
              to="/studios/$handle/members"
              params={{ handle }}
              className="text-gray-600 hover:text-gray-900 [&.active]:text-blue-600 [&.active]:font-medium"
            >
              Members
            </Link>
          </li>
        </ul>
      </nav>
      <Outlet />
    </div>
  )
}
