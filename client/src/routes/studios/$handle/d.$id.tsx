import React from "react"
import { createFileRoute } from "@tanstack/react-router"
import { DecisionDetail } from "@/components/DecisionDetail"

export const Route = createFileRoute("/studios/$handle/d/$id")({
  component: DecisionDetailRoute,
})

function DecisionDetailRoute(): React.ReactElement {
  const { id } = Route.useParams()
  return <DecisionDetail decisionId={id} />
}
