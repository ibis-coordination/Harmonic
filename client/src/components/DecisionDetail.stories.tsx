import React from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { Decision } from "@/services/types"

// Create a presentational version of DecisionDetail that doesn't make API calls
// This allows us to test the component in isolation with controlled data

interface DecisionDetailPresentationalProps {
  decision: Decision
  isLoading?: boolean | undefined
  error?: boolean | undefined
}

function DecisionDetailPresentational({
  decision,
  isLoading = false,
  error = false,
}: DecisionDetailPresentationalProps): React.ReactElement {
  if (isLoading) {
    return (
      <div className="flex justify-center py-8">
        <p className="text-gray-500">Loading...</p>
      </div>
    )
  }

  if (error) {
    return (
      <div className="py-8">
        <p className="text-red-600">Error loading decision</p>
      </div>
    )
  }

  const title = decision.question || "(untitled)"
  const options = decision.options ?? []
  const results = decision.results ?? []
  const voterLabel = decision.voter_count === 1 ? "voter" : "voters"

  return (
    <div className="space-y-8">
      <h1 className="text-2xl font-bold text-gray-900">Decision: {title}</h1>

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
              <li
                key={option.id}
                className="bg-white border border-gray-200 rounded-lg p-4"
              >
                <h3 className="font-medium text-gray-900">{option.title}</h3>
                {option.description && (
                  <p className="text-sm text-gray-600 mt-1">
                    {option.description}
                  </p>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Results</h2>
        {results.length === 0 ? (
          <p className="text-gray-500">No votes yet.</p>
        ) : (
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
        )}
      </section>
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

const mockDecision: Decision = {
  id: 1,
  truncated_id: "8d3d2c55",
  question: "What should we have for Taco Tuesday?",
  description: "Let's decide on the taco filling options for this week.",
  options_open: true,
  deadline: "2026-01-20T23:59:59.000Z",
  created_at: "2026-01-19T07:32:38.000Z",
  updated_at: "2026-01-19T07:32:38.000Z",
  voter_count: 3,
  options: [
    {
      id: 1,
      random_id: "992123456",
      title: "Carnitas",
      description: null,
      decision_id: 1,
      decision_participant_id: 1,
      created_at: "2026-01-19T07:32:38.000Z",
      updated_at: "2026-01-19T07:32:38.000Z",
    },
    {
      id: 2,
      random_id: "263789012",
      title: "Barbacoa",
      description: "Slow-cooked beef with chipotle",
      decision_id: 1,
      decision_participant_id: 1,
      created_at: "2026-01-19T07:32:38.000Z",
      updated_at: "2026-01-19T07:32:38.000Z",
    },
    {
      id: 3,
      random_id: "190345678",
      title: "Al Pastor",
      description: "Marinated pork with pineapple",
      decision_id: 1,
      decision_participant_id: 1,
      created_at: "2026-01-19T07:32:38.000Z",
      updated_at: "2026-01-19T07:32:38.000Z",
    },
  ],
  results: [
    {
      position: 1,
      decision_id: 1,
      option_id: 1,
      option_title: "Carnitas",
      option_random_id: "992123456",
      accepted_yes: 3,
      accepted_no: 0,
      vote_count: 3,
      preferred: 2,
    },
    {
      position: 2,
      decision_id: 1,
      option_id: 2,
      option_title: "Barbacoa",
      option_random_id: "263789012",
      accepted_yes: 2,
      accepted_no: 1,
      vote_count: 3,
      preferred: 1,
    },
    {
      position: 3,
      decision_id: 1,
      option_id: 3,
      option_title: "Al Pastor",
      option_random_id: "190345678",
      accepted_yes: 1,
      accepted_no: 2,
      vote_count: 3,
      preferred: 0,
    },
  ],
}

const queryClient = new QueryClient()

const meta = {
  title: "Components/DecisionDetail",
  component: DecisionDetailPresentational,
  parameters: {
    layout: "padded",
  },
  tags: ["autodocs"],
  decorators: [
    (Story) => (
      <QueryClientProvider client={queryClient}>
        <Story />
      </QueryClientProvider>
    ),
  ],
} satisfies Meta<typeof DecisionDetailPresentational>

export default meta
type Story = StoryObj<typeof meta>

/**
 * Default state showing a decision with options and votes.
 */
export const Default: Story = {
  args: {
    decision: mockDecision,
  },
}

/**
 * Loading state while fetching decision data.
 */
export const Loading: Story = {
  args: {
    decision: mockDecision,
    isLoading: true,
  },
}

/**
 * Error state when decision fails to load.
 */
export const Error: Story = {
  args: {
    decision: mockDecision,
    error: true,
  },
}

/**
 * Decision with no description.
 */
export const NoDescription: Story = {
  args: {
    decision: {
      ...mockDecision,
      description: null,
    },
  },
}

/**
 * Decision with no options yet.
 */
export const NoOptions: Story = {
  args: {
    decision: {
      ...mockDecision,
      options: [],
      results: [],
    },
  },
}

/**
 * Decision with no votes yet.
 */
export const NoVotes: Story = {
  args: {
    decision: {
      ...mockDecision,
      voter_count: 0,
      results: [],
    },
  },
}

/**
 * Decision with no deadline.
 */
export const NoDeadline: Story = {
  args: {
    decision: {
      ...mockDecision,
      deadline: null,
    },
  },
}
