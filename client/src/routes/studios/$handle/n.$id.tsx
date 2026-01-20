import { createFileRoute } from "@tanstack/react-router"
import { NoteDetail } from "@/components/NoteDetail"

export const Route = createFileRoute("/studios/$handle/n/$id")({
  component: NoteDetailRoute,
})

function NoteDetailRoute() {
  const { id } = Route.useParams()
  return <NoteDetail noteId={id} />
}
