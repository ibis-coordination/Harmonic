# Storybook Skill

Guidelines for developing and documenting React components with Storybook in the Harmonic V2 client.

## Running Storybook

**Commands:**
```bash
cd client

# Start dev server at http://localhost:6006
npm run storybook

# Build static site to storybook-static/
npm run build-storybook
```

## Creating Stories

Stories are placed alongside components with `.stories.tsx` extension:

```
src/components/
├── ComponentName.tsx
├── ComponentName.stories.tsx   # Stories
└── ComponentName.test.tsx      # Tests
```

### Basic Story Template

```typescript
import type { Meta, StoryObj } from '@storybook/react-vite'
import { ComponentName } from './ComponentName'

const meta = {
  title: 'Components/ComponentName',
  component: ComponentName,
  parameters: {
    layout: 'padded',  // 'centered' | 'fullscreen' | 'padded'
  },
  tags: ['autodocs'],
} satisfies Meta<typeof ComponentName>

export default meta
type Story = StoryObj<typeof meta>

export const Default: Story = {
  args: {
    // Component props
  },
}
```

### Story Variants

```typescript
// Different states
export const Loading: Story = {
  args: { isLoading: true },
}

export const Error: Story = {
  args: { error: 'Something went wrong' },
}

export const Empty: Story = {
  args: { items: [] },
}

// Custom render
export const WithWrapper: Story = {
  render: (args) => (
    <div className="p-4 bg-gray-100">
      <ComponentName {...args} />
    </div>
  ),
}
```

## Global Context

All stories are automatically wrapped with:
- **QueryClientProvider** - React Query hooks work
- **RouterProvider** - TanStack Router hooks work
- **Tailwind CSS** - Styles from `index.css`

Configuration: `.storybook/preview.ts`

## Title Organization

Use `/` for sidebar hierarchy:

| Pattern | Sidebar Location |
|---------|-----------------|
| `'Button'` | Root level |
| `'Components/Button'` | Components > Button |
| `'Components/Forms/TextInput'` | Components > Forms > TextInput |
| `'Pages/Home'` | Pages > Home |

## Installed Addons

| Addon | Purpose | Access |
|-------|---------|--------|
| `addon-docs` | Auto-generated docs | "Docs" tab |
| `addon-a11y` | Accessibility testing | "Accessibility" panel |
| `addon-onboarding` | Tutorial | First run only |

## Components with API Calls

For components that fetch data, options:

1. **Extract presentational component** - Separate data fetching from rendering
2. **Mock with decorators** - Provide mock data via story decorator
3. **Use MSW addon** - Mock at network level (requires additional setup)

Example decorator approach:
```typescript
export const WithMockData: Story = {
  decorators: [
    (Story) => {
      // Set up mock query client with data
      return <Story />
    },
  ],
}
```

## File Locations

| File | Purpose |
|------|---------|
| `client/.storybook/main.ts` | Storybook config, addons |
| `client/.storybook/preview.ts` | Global decorators, styles |
| `client/src/**/*.stories.tsx` | Component stories |
| `client/storybook-static/` | Build output (gitignored) |

## Common Patterns

### Multiple Stories for States
```typescript
export const Default: Story = { args: { status: 'idle' } }
export const Loading: Story = { args: { status: 'loading' } }
export const Success: Story = { args: { status: 'success', data: mockData } }
export const Error: Story = { args: { status: 'error', error: 'Failed' } }
```

### Args with Actions
```typescript
import { fn } from 'storybook/test'

const meta = {
  // ...
  args: {
    onClick: fn(),
    onSubmit: fn(),
  },
} satisfies Meta<typeof Component>
```

### Responsive Testing
```typescript
export const Mobile: Story = {
  parameters: {
    viewport: { defaultViewport: 'mobile1' },
  },
}
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

## Cleanup

Remove example stories when ready:
```bash
rm -rf client/src/stories/
```

## Documentation

Full documentation: [docs/STORYBOOK.md](../../docs/STORYBOOK.md)
