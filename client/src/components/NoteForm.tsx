import { useState } from "react"
import { useMutation } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { NotesService, runApiEffect } from "@/services/api"
import type { Note } from "@/services/types"

interface NoteFormProps {
  handle: string
}

export function NoteForm({ handle }: NoteFormProps) {
  const navigate = useNavigate()
  const [text, setText] = useState("")
  const [error, setError] = useState<string | null>(null)

  const createNoteMutation = useMutation({
    mutationFn: (data: { text: string }) =>
      runApiEffect(NotesService.create(data)),
    onSuccess: (note: Note) => {
      void navigate({
        to: "/studios/$handle/n/$id",
        params: { handle, id: note.truncated_id },
      })
    },
    onError: () => {
      setError("Error creating note. Please try again.")
    },
  })

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)
    createNoteMutation.mutate({ text })
  }

  const isSubmitting = createNoteMutation.isPending
  const canSubmit = text.trim().length > 0 && !isSubmitting

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold text-gray-900">New Note</h1>

      <p className="text-gray-600">
        Notes only require text content (markdown). Any links to other resources
        within the studio should include the full URL, not just the path.
      </p>

      {error && (
        <div className="p-4 bg-red-50 border border-red-200 rounded-lg">
          <p className="text-red-700">{error}</p>
        </div>
      )}

      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label
            htmlFor="note-text"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Text
          </label>
          <textarea
            id="note-text"
            value={text}
            onChange={(e) => { setText(e.target.value); }}
            rows={10}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 font-mono text-sm"
            placeholder="Enter your note content (markdown supported)..."
            disabled={isSubmitting}
          />
        </div>

        <div className="flex justify-end">
          <button
            type="submit"
            disabled={!canSubmit}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isSubmitting ? "Creating..." : "Create Note"}
          </button>
        </div>
      </form>
    </div>
  )
}
