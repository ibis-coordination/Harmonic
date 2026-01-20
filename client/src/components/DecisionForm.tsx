import React, { useState } from "react"
import { useMutation } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { DecisionsService, runApiEffect } from "@/services/api"
import type { Decision } from "@/services/types"

interface DecisionFormProps {
  handle: string
}

export function DecisionForm({ handle }: DecisionFormProps): React.ReactElement {
  const navigate = useNavigate()
  const [question, setQuestion] = useState("")
  const [description, setDescription] = useState("")
  const [deadline, setDeadline] = useState("")
  const [optionsOpen, setOptionsOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const createDecisionMutation = useMutation({
    mutationFn: (data: {
      question: string
      description?: string
      deadline?: string
      options_open?: boolean
    }) => runApiEffect(DecisionsService.create(data)),
    onSuccess: (decision: Decision) => {
      void navigate({
        to: "/studios/$handle/d/$id",
        params: { handle, id: decision.truncated_id },
      })
    },
    onError: () => {
      setError("Error creating decision. Please try again.")
    },
  })

  const handleSubmit = (e: React.FormEvent): void => {
    e.preventDefault()
    setError(null)

    const data: {
      question: string
      description?: string
      deadline?: string
      options_open?: boolean
    } = {
      question,
      ...(description.trim() ? { description } : {}),
      ...(deadline ? { deadline } : {}),
      ...(optionsOpen ? { options_open: optionsOpen } : {}),
    }

    createDecisionMutation.mutate(data)
  }

  const isSubmitting = createDecisionMutation.isPending
  const canSubmit = question.trim().length > 0 && !isSubmitting

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold text-gray-900">New Decision</h1>

      <p className="text-gray-600">
        Decisions require a question that the group will answer through voting.
        Options can be added after the decision is created.
      </p>

      {error && (
        <div className="p-4 bg-red-50 border border-red-200 rounded-lg">
          <p className="text-red-700">{error}</p>
        </div>
      )}

      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label
            htmlFor="decision-question"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Question
          </label>
          <input
            id="decision-question"
            type="text"
            value={question}
            onChange={(e) => {
              setQuestion(e.target.value)
            }}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            placeholder="What question should this decision answer?"
            disabled={isSubmitting}
          />
        </div>

        <div>
          <label
            htmlFor="decision-description"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Description (optional)
          </label>
          <textarea
            id="decision-description"
            value={description}
            onChange={(e) => {
              setDescription(e.target.value)
            }}
            rows={4}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 font-mono text-sm"
            placeholder="Add context or details about this decision (markdown supported)..."
            disabled={isSubmitting}
          />
        </div>

        <div>
          <label
            htmlFor="decision-deadline"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Deadline (optional)
          </label>
          <input
            id="decision-deadline"
            type="datetime-local"
            value={deadline}
            onChange={(e) => {
              setDeadline(e.target.value)
            }}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            disabled={isSubmitting}
          />
        </div>

        <div className="flex items-center gap-2">
          <input
            id="decision-options-open"
            type="checkbox"
            checked={optionsOpen}
            onChange={(e) => {
              setOptionsOpen(e.target.checked)
            }}
            className="h-4 w-4 text-blue-600 border-gray-300 rounded focus:ring-blue-500"
            disabled={isSubmitting}
          />
          <label
            htmlFor="decision-options-open"
            className="text-sm text-gray-700"
          >
            Allow anyone to add options
          </label>
        </div>

        <div className="flex justify-end">
          <button
            type="submit"
            disabled={!canSubmit}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isSubmitting ? "Creating..." : "Create Decision"}
          </button>
        </div>
      </form>
    </div>
  )
}
