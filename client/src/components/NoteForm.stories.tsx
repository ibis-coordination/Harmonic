import type { Meta, StoryObj } from '@storybook/react-vite'
import { NoteForm } from './NoteForm'

const meta = {
  title: 'Components/NoteForm',
  component: NoteForm,
  parameters: {
    layout: 'padded',
  },
  tags: ['autodocs'],
} satisfies Meta<typeof NoteForm>

export default meta
type Story = StoryObj<typeof meta>

/**
 * Default empty state for creating a new note.
 */
export const Default: Story = {
  args: {
    handle: 'demo-studio',
  },
}
