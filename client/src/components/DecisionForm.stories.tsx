import type { Meta, StoryObj } from "@storybook/react-vite"
import { DecisionForm } from "./DecisionForm"

const meta = {
  title: "Components/DecisionForm",
  component: DecisionForm,
  parameters: {
    layout: "padded",
  },
  tags: ["autodocs"],
} satisfies Meta<typeof DecisionForm>

export default meta
type Story = StoryObj<typeof meta>

/**
 * Default empty state for creating a new decision.
 */
export const Default: Story = {
  args: {
    handle: "demo-studio",
  },
}
