import { createFileRoute } from "@tanstack/react-router"
import { NoteForm } from "@/components/NoteForm"

export const Route = createFileRoute("/studios/$handle/note")({
  component: NoteFormRoute,
})

function NoteFormRoute() {
  const { handle } = Route.useParams()
  return <NoteForm handle={handle} />
}
