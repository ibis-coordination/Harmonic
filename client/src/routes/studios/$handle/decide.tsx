import React from "react"
import { createFileRoute } from "@tanstack/react-router"
import { DecisionForm } from "@/components/DecisionForm"

export const Route = createFileRoute("/studios/$handle/decide")({
  component: DecideRoute,
})

function DecideRoute(): React.ReactElement {
  const { handle } = Route.useParams()
  return <DecisionForm handle={handle} />
}
