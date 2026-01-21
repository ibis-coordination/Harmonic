# Storybook

Storybook is an isolated development environment for building, testing, and documenting React components.

## Quick Start

```bash
cd client

# Start dev server at http://localhost:6006
npm run storybook

# Build static site to storybook-static/
npm run build-storybook
```

## Writing Stories

Stories are placed alongside components with the `.stories.tsx` extension:

```
src/components/
├── NoteForm.tsx
├── NoteForm.stories.tsx    # Stories for NoteForm
├── NoteForm.test.tsx       # Tests for NoteForm
```

### Basic Story Structure

```typescript
// ComponentName.stories.tsx
import type { Meta, StoryObj } from '@storybook/react-vite'
import { ComponentName } from './ComponentName'

const meta = {
  title: 'Components/ComponentName',  // Sidebar location
  component: ComponentName,
  parameters: {
    layout: 'padded',  // 'centered' | 'fullscreen' | 'padded'
  },
  tags: ['autodocs'],  // Enable auto-generated docs
} satisfies Meta<typeof ComponentName>

export default meta
type Story = StoryObj<typeof meta>

// Each named export is a story
export const Default: Story = {
  args: {
    // Props to pass to the component
    title: 'Example',
  },
}

export const Loading: Story = {
  args: {
    title: 'Example',
    isLoading: true,
  },
}
```

### Story with Custom Render

```typescript
export const WithWrapper: Story = {
  args: {
    title: 'Example',
  },
  render: (args) => (
    <div className="p-4 bg-gray-100">
      <ComponentName {...args} />
    </div>
  ),
}
```

### Story with Play Function (Interaction Testing)

```typescript
import { userEvent, within } from 'storybook/test'

export const FilledForm: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await userEvent.type(canvas.getByLabelText('Title'), 'My Title')
    await userEvent.click(canvas.getByRole('button', { name: 'Submit' }))
  },
}
```

## Global Configuration

### Decorators (preview.ts)

All stories are wrapped with:
- **QueryClientProvider** - React Query context
- **RouterProvider** - TanStack Router context
- **Tailwind CSS** - Global styles from `index.css`

To add additional global wrappers, edit `.storybook/preview.ts`.

### Addons

| Addon | Purpose |
|-------|---------|
| `@storybook/addon-docs` | Auto-generated documentation from TypeScript types |
| `@storybook/addon-a11y` | Accessibility testing panel |
| `@storybook/addon-onboarding` | Interactive tutorial for new users |

To add more addons, install the package and add to `.storybook/main.ts`.

## Organizing Stories

### Title Hierarchy

Use `/` in titles to create sidebar groups:

```typescript
// Flat
title: 'Button'

// Grouped
title: 'Components/Button'
title: 'Components/Forms/TextInput'
title: 'Pages/Home'
```

### Recommended Structure

```
Components/
├── NoteForm
├── NoteDetail
├── Button
└── ...

Pages/
├── Home
├── StudioOverview
└── ...

Example/          # Storybook's example stories (can be removed)
├── Button
├── Header
└── Page
```

## Documentation with MDX

Create `.mdx` files for rich documentation:

```mdx
{/* ComponentName.mdx */}
import { Meta, Story, Canvas } from '@storybook/blocks'
import * as Stories from './ComponentName.stories'

<Meta of={Stories} />

# ComponentName

Description of what this component does.

## Usage

<Canvas of={Stories.Default} />

## Props

The component accepts the following props...
```

## Testing

### Accessibility Testing

1. Open any story in Storybook
2. Click the "Accessibility" tab in the addons panel
3. Review any violations or warnings

### Visual Testing

For visual regression testing, consider adding [Chromatic](https://www.chromatic.com/) integration.

## Removing Example Stories

The example stories in `src/stories/` can be removed once you're familiar with the patterns:

```bash
rm -rf client/src/stories/
```

## Linting

Story files follow the same ESLint rules as the rest of the V2 client, with some relaxations:

- Storybook files (`*.stories.tsx`) have relaxed TypeScript `unsafe` rules for easier mocking
- All functional programming rules still apply (no classes, no `let`, no loops, no `throw`)

Run linting before committing:
```bash
cd client && npm run lint
```

ESLint configuration: `client/eslint.config.js`

### Optional Props in Stories

When defining props for stories, use `| undefined` for optional props to satisfy `exactOptionalPropertyTypes`:

```typescript
interface ButtonProps {
  label: string
  onClick?: (() => void) | undefined  // Not just onClick?: () => void
}
```

## Troubleshooting

### Component needs providers not in preview.ts

Add a story-specific decorator:

```typescript
export const WithCustomProvider: Story = {
  decorators: [
    (Story) => (
      <SomeProvider>
        <Story />
      </SomeProvider>
    ),
  ],
}
```

### Component makes API calls

Options:
1. Mock at the network level with [MSW addon](https://storybook.js.org/addons/msw-storybook-addon)
2. Create a presentational version of the component
3. Use story-specific decorators to provide mock data

### TypeScript errors in stories

Ensure you're using the correct import:
```typescript
import type { Meta, StoryObj } from '@storybook/react-vite'
```

## Resources

- [Storybook Docs](https://storybook.js.org/docs)
- [Writing Stories](https://storybook.js.org/docs/writing-stories)
- [Addon Catalog](https://storybook.js.org/addons)
