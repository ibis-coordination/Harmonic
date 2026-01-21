import { createFileRoute } from "@tanstack/react-router"
import { useQuery } from "@tanstack/react-query"
import { StudiosService, UsersService, runApiEffect } from "@/services/api"
import type { Studio, User } from "@/services/types"

export const Route = createFileRoute("/studios/$handle/")({
  component: StudioOverviewRoute,
})

function StudioOverviewRoute() {
  const { handle } = Route.useParams()
  return <StudioOverview handle={handle} />
}

interface StudioOverviewProps {
  handle: string
}

export function StudioOverview({ handle }: StudioOverviewProps) {
  const { data: studio, isLoading: isLoadingStudio } = useQuery<Studio>({
    queryKey: ["studio", handle],
    queryFn: () => runApiEffect(StudiosService.get(handle)),
  })

  const { data: teamMembers = [], isLoading: isLoadingTeam } = useQuery<User[]>({
    queryKey: ["users"],
    queryFn: () => runApiEffect(UsersService.list()),
  })

  const isLoading = isLoadingStudio || isLoadingTeam
  const studioName = studio?.name ?? handle

  if (isLoading) {
    return (
      <div>
        <p className="text-gray-500">Loading...</p>
      </div>
    )
  }

  return (
    <div>
      <h1 className="text-2xl font-bold text-gray-900 mb-6">
        Studio: {studioName}
      </h1>

      <section className="mb-8">
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Explore</h2>
        <ul className="space-y-2">
          <li>
            <a
              href={`/studios/${handle}/cycles`}
              className="text-blue-600 hover:text-blue-800 hover:underline"
            >
              Cycles
            </a>
          </li>
          <li>
            <a
              href={`/studios/${handle}/backlinks`}
              className="text-blue-600 hover:text-blue-800 hover:underline"
            >
              Backlinks
            </a>
          </li>
        </ul>
      </section>

      <section className="mb-8">
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Pinned</h2>
        <p className="text-gray-500">No pinned items yet.</p>
      </section>

      <section className="mb-8">
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Team</h2>
        {teamMembers.length === 0 ? (
          <p className="text-gray-500">No team members yet.</p>
        ) : (
          <ul className="space-y-2">
            {teamMembers.map((member) => (
              <li key={member.id}>
                <a
                  href={`/u/${member.handle}`}
                  className="text-blue-600 hover:text-blue-800 hover:underline"
                >
                  {member.display_name}
                </a>
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
              href={`/studios/${handle}/note`}
              className="text-blue-600 hover:text-blue-800 hover:underline"
            >
              New Note
            </a>
          </li>
          <li>
            <a
              href={`/studios/${handle}/decide`}
              className="text-blue-600 hover:text-blue-800 hover:underline"
            >
              New Decision
            </a>
          </li>
          <li>
            <a
              href={`/studios/${handle}/commit`}
              className="text-blue-600 hover:text-blue-800 hover:underline"
            >
              New Commitment
            </a>
          </li>
        </ul>
      </section>
    </div>
  )
}
