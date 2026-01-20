import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { NotesService, runApiEffect } from "@/services/api"
import type { Note, NoteHistoryEvent } from "@/services/types"

interface NoteDetailProps {
  noteId: string
}

export function NoteDetail({ noteId }: NoteDetailProps) {
  const queryClient = useQueryClient()

  const {
    data: note,
    isLoading,
    error,
  } = useQuery<Note>({
    queryKey: ["note", noteId],
    queryFn: () =>
      runApiEffect(NotesService.get(noteId, { include: ["history_events"] })),
  })

  const confirmReadMutation = useMutation({
    mutationFn: () => runApiEffect(NotesService.confirmRead(noteId)),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["note", noteId] })
    },
  })

  if (isLoading) {
    return (
      <div className="flex justify-center py-8">
        <p className="text-gray-500">Loading...</p>
      </div>
    )
  }

  if (error || !note) {
    return (
      <div className="py-8">
        <p className="text-red-600">Error loading note</p>
      </div>
    )
  }

  const title = note.title ?? "(untitled)"
  const historyEvents = note.history_events ?? []

  return (
    <div className="space-y-8">
      <h1 className="text-2xl font-bold text-gray-900">Note: {title}</h1>

      <NoteMetadata note={note} />

      <section>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Text</h2>
        <div className="bg-gray-50 rounded-lg p-4 border border-gray-200">
          <pre className="whitespace-pre-wrap font-mono text-sm text-gray-800">
            {note.text}
          </pre>
        </div>
      </section>

      <section>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">History</h2>
        {historyEvents.length === 0 ? (
          <p className="text-gray-500">No history events yet.</p>
        ) : (
          <ul className="space-y-2">
            {historyEvents.map((event) => (
              <HistoryEventItem key={event.id} event={event} />
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Actions</h2>
        <div className="space-y-2">
          <button
            onClick={() => { confirmReadMutation.mutate(); }}
            disabled={confirmReadMutation.isPending}
            className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50"
          >
            {confirmReadMutation.isPending
              ? "Confirming..."
              : "Confirm Read"}
          </button>
        </div>
      </section>
    </div>
  )
}

interface NoteMetadataProps {
  note: Note
}

function NoteMetadata({ note }: NoteMetadataProps) {
  return (
    <dl className="grid grid-cols-2 gap-4 text-sm">
      <div>
        <dt className="text-gray-500">Created</dt>
        <dd className="text-gray-900">{formatDate(note.created_at)}</dd>
      </div>
      <div>
        <dt className="text-gray-500">Updated</dt>
        <dd className="text-gray-900">{formatDate(note.updated_at)}</dd>
      </div>
      {note.deadline && (
        <div>
          <dt className="text-gray-500">Deadline</dt>
          <dd className="text-gray-900">{formatDate(note.deadline)}</dd>
        </div>
      )}
      <div>
        <dt className="text-gray-500">Reads</dt>
        <dd className="text-gray-900">{note.confirmed_reads} confirmed reads</dd>
      </div>
    </dl>
  )
}

interface HistoryEventItemProps {
  event: NoteHistoryEvent
}

function HistoryEventItem({ event }: HistoryEventItemProps) {
  return (
    <li className="text-sm text-gray-700">
      <span className="text-gray-500">{formatDate(event.happened_at)}</span>
      {" — "}
      <span>{event.description}</span>
    </li>
  )
}

function formatDate(dateString: string): string {
  const date = new Date(dateString)
  return date.toLocaleString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  })
}
