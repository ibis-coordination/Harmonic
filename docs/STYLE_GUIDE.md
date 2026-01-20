# Harmonic Style Guide

This guide documents the visual design patterns used in the Harmonic application.

## Color System

Harmonic uses a GitHub-inspired color system with CSS custom properties for light/dark mode support.

### Light Mode Colors

| Variable | Value | Usage |
|----------|-------|-------|
| `--color-fg-default` | #24292f | Primary text |
| `--color-fg-muted` | #57606a | Secondary text |
| `--color-fg-subtle` | #6e7781 | Tertiary text |
| `--color-canvas-default` | #ffffff | Primary background |
| `--color-canvas-subtle` | #f6f8fa | Secondary background |
| `--color-border-default` | #d0d7de | Standard borders |
| `--color-border-muted` | hsla(210,18%,87%,1) | Subtle borders |
| `--color-accent-fg` | #0969da | Links, interactive elements |
| `--color-attention-subtle` | #fff8c5 | Warnings, alerts |
| `--color-danger-fg` | #cf222e | Errors, destructive actions |
| `--color-neutral-muted` | rgba(175,184,193,0.2) | Neutral backgrounds |

### Dark Mode Colors

| Variable | Value | Usage |
|----------|-------|-------|
| `--color-fg-default` | #c9d1d9 | Primary text |
| `--color-canvas-default` | #0d1117 | Primary background |
| `--color-canvas-subtle` | #161b22 | Secondary background |
| `--color-border-default` | #30363d | Standard borders |
| `--color-accent-fg` | #58a6ff | Links, interactive elements |
| `--color-attention-subtle` | rgba(187,128,9,0.15) | Warnings, alerts |

---

## Typography

### Font Stacks

**Primary (sans-serif):**
```css
-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif, "Apple Color Emoji", "Segoe UI Emoji"
```

**Monospace:**
```css
"Source Code Pro", "Lucida Console", monospace
```

### Base Settings

- Font size: 16px
- Line height: 1.5
- Word wrap: break-word

### Headings

| Level | Size | Weight | Notes |
|-------|------|--------|-------|
| h1 | 2em | 600 | Bottom border |
| h2 | 1.5em | 600 | - |
| h3 | 1.25em | 600 | - |
| h4-h6 | Scale down | 600 | - |

---

## Spacing

### Common Values

| Size | Pixels | Usage |
|------|--------|-------|
| XS | 2-4px | Tight gaps |
| SM | 5-10px | Component padding |
| MD | 12-16px | Section spacing |
| LG | 24-40px | Major sections |
| XL | 46px+ | Page margins |

### Layout Widths

- Content max-width: `min(88vw, 800px)`
- Form inputs: max 600px
- Mobile breakpoint: 768px

---

## Components

### Buttons

**Standard Button:**
```css
button {
  background: var(--color-fg-default);
  color: var(--color-canvas-default);
  padding: 5px 10px;
  border: 1px solid var(--color-canvas-subtle);
  border-radius: 4px;
  font-size: 16px;
  cursor: pointer;
}
```

**Text Button:**
```css
.text-only-button {
  color: var(--color-accent-fg);
  background: transparent;
  border: none;
  cursor: pointer;
}
```

**Danger Button:**
```css
.button-danger {
  background-color: #cf222e;
  color: white;
  border-color: #cf222e;
}
.button-danger:hover {
  background-color: #a40e26;
}
```

### Form Inputs

**Text Input / Textarea:**
```css
input[type="text"], textarea {
  min-width: 66%;
  max-width: 600px;
  font-size: 16px;
}

textarea {
  height: 6em;
  font-family: inherit;
}
```

**Select:**
```css
select {
  background-color: var(--color-canvas-subtle);
  border: 1px solid var(--color-fg-subtle);
  padding: 5px;
  border-radius: 4px;
  font-size: 16px;
}
```

**Focus States:**
```css
input:focus, select:focus {
  outline: 2px solid var(--color-accent-fg);
  outline-offset: -2px;
}
```

### Cards & Containers

**Basic Card:**
```css
.card {
  background-color: var(--color-canvas-default);
  border: 1px solid var(--color-border-default);
  padding: 16px;
  margin-bottom: 16px;
}
```

**Flex Card:**
```css
.subagent-card {
  display: flex;
  gap: 16px;
  border: 1px solid var(--color-border-default);
  padding: 16px;
  background-color: var(--color-canvas-default);
}
```

### Alerts & Notices

```css
.alert, .notice {
  padding: 10px;
  background-color: var(--color-neutral-muted);
  border: 1px solid var(--color-border-default);
  margin-bottom: 12px;
}

.alert-danger {
  background-color: var(--color-attention-subtle);
  border-color: var(--color-danger-fg);
}
```

### Dropdown Menus

```css
.dropdown-menu {
  position: absolute;
  background-color: var(--color-canvas-default);
  border: 1px solid var(--color-border-default);
  border-radius: 6px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.15);
  padding: 8px;
  z-index: 100;
}
```

### Badges

```css
.notification-badge {
  position: absolute;
  top: -4px;
  right: -6px;
  background-color: var(--color-accent-fg);
  width: 16px;
  height: 16px;
  line-height: 16px;
  font-size: 11px;
  font-weight: bold;
  border-radius: 50%;
  text-align: center;
}
```

### Lists

**Attachments / Tags:**
```css
.attachments-list {
  list-style: none;
  padding: 0;
  margin: 0;
}

.attachments-list li {
  display: inline-block;
  padding: 5px 10px;
  border: 1px solid var(--color-border-default);
  border-radius: 5px;
  background-color: var(--color-canvas-subtle);
}
```

---

## Icons

Harmonic uses [GitHub Octicons](https://primer.style/octicons/) via the `octicons_helper` gem.

### Usage

```erb
<%= octicon 'icon-name', height: 16 %>
```

### Common Icons

| Icon | Usage |
|------|-------|
| `note` | Notes |
| `check-circle` | Decisions |
| `heart` | Commitments |
| `plus` | Add actions |
| `pencil` | Edit |
| `gear` | Settings |
| `pin` | Pinned items |
| `link` | Links/references |
| `comment` | Comments |
| `kebab-horizontal` | More menu |

### Icon Sizes

- Default: 16px (inline)
- Medium: 22-24px
- Large: 31-36px

---

## Layout Patterns

### Page Container

```css
.page-container {
  max-width: min(88vw, 800px);
  margin: 0 auto;
}
```

### Flex Row

```css
.flex-row {
  display: flex;
  align-items: center;
  gap: 16px;
}

.flex-row-between {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
```

### Collapsible Sections

```html
<div class="collapsible">
  <div class="collapsible-header">
    <!-- Toggle icon + title -->
  </div>
  <div class="collapsible-body">
    <!-- Content -->
  </div>
</div>
```

---

## Class Naming Conventions

### Component Classes

| Pattern | Example | Usage |
|---------|---------|-------|
| Component name | `.mention-dropdown` | Main container |
| Component-element | `.mention-item` | Child elements |
| Component-state | `.mention-item-selected` | State variants |

### Utility Classes

- `.text-only-button` - Text-styled button
- `.markdown-body` - GitHub markdown wrapper
- `.user-generated-markdown` - User content styling

### Resource Type Classes

- `.note-icon`, `.decision-icon`, `.commitment-icon`
- `.resource-link-note`, `.resource-link-decision`, `.resource-link-commitment`

---

## Animations & Transitions

### Button Transitions

```css
button {
  transition: background-color 0.3s ease;
}
```

### Menu Transitions

```css
.menu {
  transition: opacity 0.15s ease;
}
```

### Spinner Animation

```css
@keyframes spin {
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
}

.spinner {
  animation: spin 0.8s linear infinite;
}
```

---

## Accessibility

### Focus States

All interactive elements must have visible focus states:

```css
:focus {
  outline: 2px solid var(--color-accent-fg);
  outline-offset: -2px;
}

:focus-visible {
  outline: 2px solid var(--color-accent-fg);
  outline-offset: -2px;
}
```

### Disabled States

```css
button:disabled {
  background-color: var(--color-border-default);
  cursor: not-allowed;
}
```

---

## React/Tailwind (V2 UI)

The V2 client uses Tailwind CSS with strict functional programming enforcement via ESLint.

### Functional Programming Rules

ESLint enforces functional programming via `eslint-plugin-functional`:

| Rule | What it forbids | Alternative |
|------|-----------------|-------------|
| `no-classes` | `class Foo {}` | Factory functions, tagged unions |
| `no-let` | `let x = 1` | `const` only |
| `no-loop-statements` | `for`, `while` | `map`, `filter`, `reduce`, recursion |
| `no-throw-statements` | `throw new Error()` | Effect.js `Effect.fail` |
| `immutable-data` | `obj.x = 1`, `arr.push()` | Spread syntax, `.map()` |

Configuration: `client/eslint.config.js`

### Error Handling Pattern

Use tagged unions instead of classes:

```typescript
// Define error types as interfaces
interface NetworkError {
  readonly _tag: "NetworkError"
  readonly message: string
  readonly cause?: unknown
}

// Factory function (not class)
const NetworkError = (params: Omit<NetworkError, "_tag">): NetworkError => ({
  _tag: "NetworkError",
  ...params,
})

// Type guard
const isNetworkError = (error: HttpError): error is NetworkError =>
  error._tag === "NetworkError"
```

### Effect.js Patterns

Use `Effect.gen` for sequential operations with error handling:

```typescript
const fetchData = (id: string): Effect.Effect<Data, HttpError> =>
  Effect.gen(function* () {
    const response = yield* Effect.tryPromise({
      try: () => fetch(`/api/data/${id}`),
      catch: (error): HttpError => NetworkError({ message: String(error), cause: error }),
    })
    if (!response.ok) {
      return yield* Effect.fail(ApiError({ status: response.status, message: "Failed" }))
    }
    return yield* Effect.tryPromise({
      try: () => response.json() as Promise<Data>,
      catch: (): HttpError => ApiError({ status: 500, message: "Invalid JSON" }),
    })
  })
```

### Tailwind CSS Patterns

Common patterns:

### Container

```jsx
<div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
```

### Header

```jsx
<header className="border-b border-gray-200 bg-white">
  <div className="flex h-14 items-center justify-between">
```

### Buttons

```jsx
<button className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50">
```

### Form Inputs

```jsx
<input className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
```

### Error States

```jsx
<div className="p-4 bg-red-50 border border-red-200 rounded-lg">
```

---

## Quick Reference

| Element | Background | Border | Text | Padding |
|---------|------------|--------|------|---------|
| Button | `--color-fg-default` | 1px subtle | `--color-canvas-default` | 5px 10px |
| Card | `--color-canvas-default` | 1px default | inherit | 16px |
| Input | inherit | 1px subtle | inherit | 5px |
| Alert | `--color-neutral-muted` | 1px default | inherit | 10px |
| Dropdown | `--color-canvas-default` | 1px + shadow | inherit | 8px |
