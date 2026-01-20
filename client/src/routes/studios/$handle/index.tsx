import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/studios/$handle/")({
  component: StudioOverview,
})

function StudioOverview() {
  const { handle } = Route.useParams()

  return (
    <div>
      <h1 className="text-2xl font-bold text-gray-900 mb-4">
        Studio: {handle}
      </h1>
      <p className="text-gray-600">
        Welcome to the v2 UI. This is a placeholder for the studio overview.
      </p>

      <div className="mt-8 grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-lg font-medium text-gray-900 mb-2">Notes</h2>
          <p className="text-gray-500 text-sm">Share information with your studio</p>
        </div>
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-lg font-medium text-gray-900 mb-2">Decisions</h2>
          <p className="text-gray-500 text-sm">Make collective decisions together</p>
        </div>
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-lg font-medium text-gray-900 mb-2">Commitments</h2>
          <p className="text-gray-500 text-sm">Coordinate actions with critical mass</p>
        </div>
      </div>
    </div>
  )
}
