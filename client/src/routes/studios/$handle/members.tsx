import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/studios/$handle/members")({
  component: StudioMembers,
})

function StudioMembers() {
  const { handle } = Route.useParams()

  return (
    <div>
      <h1 className="text-2xl font-bold text-gray-900 mb-4">Members</h1>
      <p className="text-gray-600">
        Members of {handle} will be listed here.
      </p>
    </div>
  )
}
