import React from "react"
import { useQuery } from "@tanstack/react-query"
import { DecisionsService, runApiEffect } from "@/services/api"
import type { Decision, DecisionOption, DecisionResult } from "@/services/types"

interface DecisionDetailProps {
  decisionId: string
}

export function DecisionDetail({ decisionId }: DecisionDetailProps): React.ReactElement {
  const {
    data: decision,
    isLoading,
    error,
  } = useQuery<Decision>({
    queryKey: ["decision", decisionId],
    queryFn: () =>
      runApiEffect(
        DecisionsService.get(decisionId, { include: ["options", "results"] }),
      ),
  })

  if (isLoading) {
    return (
      <div className="flex justify-center py-8">
        <p className="text-gray-500">Loading...</p>
      </div>
    )
  }

  if (error || !decision) {
    return (
      <div className="py-8">
        <p className="text-red-600">Error loading decision</p>
      </div>
    )
  }

  const title = decision.question || "(untitled)"
  const options = decision.options ?? []
  const results = decision.results ?? []

  return (
    <div className="space-y-8">
      <h1 className="text-2xl font-bold text-gray-900">Decision: {title}</h1>

      <DecisionMetadata decision={decision} />

      {decision.description && (
        <section>
          <h2 className="text-xl font-semibold text-gray-900 mb-4">
            Description
          </h2>
          <div className="bg-gray-50 rounded-lg p-4 border border-gray-200">
            <p className="text-gray-800">{decision.description}</p>
          </div>
        </section>
      )}

      <section>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Options</h2>
        {options.length === 0 ? (
          <p className="text-gray-500">No options yet.</p>
        ) : (
          <ul className="space-y-3">
            {options.map((option) => (
              <OptionItem key={option.id} option={option} />
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Results</h2>
        {results.length === 0 ? (
          <p className="text-gray-500">No votes yet.</p>
        ) : (
          <ResultsTable results={results} />
        )}
      </section>
    </div>
  )
}

interface DecisionMetadataProps {
  decision: Decision
}

function DecisionMetadata({ decision }: DecisionMetadataProps): React.ReactElement {
  const voterLabel = decision.voter_count === 1 ? "voter" : "voters"

  return (
    <dl className="grid grid-cols-2 gap-4 text-sm">
      <div>
        <dt className="text-gray-500">Created</dt>
        <dd className="text-gray-900">{formatDate(decision.created_at)}</dd>
      </div>
      <div>
        <dt className="text-gray-500">Updated</dt>
        <dd className="text-gray-900">{formatDate(decision.updated_at)}</dd>
      </div>
      {decision.deadline && (
        <div>
          <dt className="text-gray-500">Deadline</dt>
          <dd className="text-gray-900">{formatDate(decision.deadline)}</dd>
        </div>
      )}
      <div>
        <dt className="text-gray-500">Voters</dt>
        <dd className="text-gray-900">
          {decision.voter_count} {voterLabel}
        </dd>
      </div>
    </dl>
  )
}

interface OptionItemProps {
  option: DecisionOption
}

function OptionItem({ option }: OptionItemProps): React.ReactElement {
  return (
    <li className="bg-white border border-gray-200 rounded-lg p-4">
      <h3 className="font-medium text-gray-900">{option.title}</h3>
      {option.description && (
        <p className="text-sm text-gray-600 mt-1">{option.description}</p>
      )}
    </li>
  )
}

interface ResultsTableProps {
  results: DecisionResult[]
}

function ResultsTable({ results }: ResultsTableProps): React.ReactElement {
  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200">
        <thead className="bg-gray-50">
          <tr>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Position
            </th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Option
            </th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Accepted
            </th>
            <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Preferred
            </th>
          </tr>
        </thead>
        <tbody className="bg-white divide-y divide-gray-200">
          {results.map((result) => (
            <tr key={result.option_id}>
              <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-900">
                {result.position}
              </td>
              <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-900">
                {result.option_title}
              </td>
              <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-900">
                {result.accepted_yes}
              </td>
              <td className="px-4 py-3 whitespace-nowrap text-sm text-gray-900">
                {result.preferred}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
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
