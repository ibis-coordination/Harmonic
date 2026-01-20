import { createFileRoute, Link } from "@tanstack/react-router"
import { useAppStore } from "@/stores/app"

export const Route = createFileRoute("/")({
  component: IndexComponent,
})

function IndexComponent() {
  const { currentUser, currentSuperagent } = useAppStore()

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">
          Welcome to Harmonic
        </h1>
        <p className="text-gray-600">
          You're using the beta version of the new UI.
          {currentUser && (
            <>
              {" "}
              You can switch back to the classic UI in{" "}
              <a
                href={`/u/${currentUser.handle}/settings`}
                className="text-blue-600 hover:text-blue-800"
              >
                your settings
              </a>
              .
            </>
          )}
        </p>
      </div>

      {currentSuperagent.handle && (
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-lg font-medium text-gray-900 mb-4">
            Current Studio
          </h2>
          <Link
            to="/studios/$handle"
            params={{ handle: currentSuperagent.handle }}
            className="text-blue-600 hover:text-blue-800 font-medium"
          >
            {currentSuperagent.name ?? currentSuperagent.handle} →
          </Link>
        </div>
      )}
    </div>
  )
}
