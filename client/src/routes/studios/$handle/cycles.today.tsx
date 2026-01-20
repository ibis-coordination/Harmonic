import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/studios/$handle/cycles/today")({
  component: CyclesToday,
})

function CyclesToday() {
  const { handle } = Route.useParams()

  return (
    <div>
      <h1 className="text-2xl font-bold text-gray-900 mb-4">Today</h1>
      <p className="text-gray-600">
        Today's activity for {handle} will be displayed here.
      </p>
    </div>
  )
}
