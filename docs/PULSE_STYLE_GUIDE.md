# Pulse Design System Style Guide

This document describes the Pulse design system used throughout the Harmonic application.

## Color Tokens

All colors are defined in `app/assets/stylesheets/root_variables.css` and automatically adapt to system light/dark mode preferences via `prefers-color-scheme` media queries.

### Foreground Colors
| Token | Light Mode | Dark Mode | Usage |
|-------|------------|-----------|-------|
| `--color-fg-default` | #24292f | #c9d1d9 | Primary text |
| `--color-fg-muted` | #57606a | #8b949e | Secondary text, timestamps |
| `--color-fg-subtle` | #6e7781 | #6e7681 | Tertiary text, placeholders |

### Canvas Colors (Backgrounds)
| Token | Light Mode | Dark Mode | Usage |
|-------|------------|-----------|-------|
| `--color-canvas-default` | #ffffff | #0d1117 | Page background |
| `--color-canvas-subtle` | #f6f8fa | #161b22 | Card backgrounds, hover states |

### Border Colors
| Token | Light Mode | Dark Mode | Usage |
|-------|------------|-----------|-------|
| `--color-border-default` | #d0d7de | #30363d | Primary borders |
| `--color-border-muted` | hsla(210,18%,87%,1) | #21262d | Subtle borders |

### Accent Colors
| Token | Light Mode | Dark Mode | Usage |
|-------|------------|-----------|-------|
| `--color-accent-fg` | #0969da | #58a6ff | Links, interactive elements |
| `--color-accent-emphasis` | #0969da | #1f6feb | Emphasized accents |

### Status Colors
| Token | Light Mode | Dark Mode | Usage |
|-------|------------|-----------|-------|
| `--color-danger-fg` | #cf222e | #f85149 | Errors, destructive actions |
| `--color-success-fg` | #1a7f37 | #3fb950 | Success messages |
| `--color-success-emphasis` | #2da44e | #238636 | Progress bars, success emphasis |
| `--color-success-subtle` | rgba(46,160,67,0.15) | rgba(46,160,67,0.15) | Success backgrounds |
| `--color-attention-subtle` | #fff8c5 | rgba(187,128,9,0.15) | Warning backgrounds |

### Utility Colors
| Token | Light Mode | Dark Mode | Usage |
|-------|------------|-----------|-------|
| `--color-neutral-muted` | rgba(175,184,193,0.2) | rgba(110,118,129,0.4) | Neutral backgrounds |

---

## Typography

### Font Stack
```css
font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
```

### Font Sizes
| Element | Size | Weight | Usage |
|---------|------|--------|-------|
| Page title | 20px | 600 | Main headings |
| Section label | 11px | 400 | Uppercase labels (e.g., "Current Cycle") |
| Body text | 14px | 400 | Default content |
| Small text | 12px | 400 | Timestamps, meta info |
| Tiny text | 13px | 400 | Button labels, counts |

### Line Height
Default: `1.5`

### Text Transforms
- Section labels: `text-transform: uppercase; letter-spacing: 0.5px`

---

## Spacing System

Based on a 4px grid with common increments of 8px.

| Size | Value | Usage |
|------|-------|-------|
| xs | 4px | Minimal gaps |
| sm | 6px | Icon gaps |
| md | 8px | Small padding |
| lg | 12px | Component gaps |
| xl | 16px | Section padding |
| 2xl | 24px | Large sections |

### Component Spacing
- **Sidebar sections**: 16px padding
- **Feed items**: 16px horizontal, 12px vertical
- **Buttons**: 8px 16px padding
- **Avatar gaps**: 6px (stacked with negative margin)

---

## Layout Patterns

### Pulse Layout Structure
```
┌─────────────────────────────────────────────────┐
│  Header (56px)                                  │
├──────────────┬──────────────────────────────────┤
│  Sidebar     │  Main Content                    │
│  (280px)     │  (flex: 1)                       │
│              │                                  │
│              │                                  │
├──────────────┴──────────────────────────────────┤
│  Footer (motto)                                 │
└─────────────────────────────────────────────────┘
```

### Sidebar Modes
1. **Full** (studio context): cycle, heartbeats, nav, pinned items, explore links
2. **Modified** (resource detail): studio info, quick actions
3. **Minimal** (user/admin): navigation only
4. **None** (auth pages): centered content

### CSS Classes
- `.pulse-container` - Main flex wrapper
- `.pulse-sidebar` - Fixed 280px sidebar
- `.pulse-main` - Flexible main content area

---

## Components

### Buttons

#### Primary Action Button
```css
.pulse-action-btn {
  background: var(--color-fg-default);
  color: var(--color-canvas-default);
  padding: 8px 16px;
  border: 1px solid var(--color-border-default);
  font-size: 14px;
  font-weight: 500;
}
```

#### Feed Action Button
```css
.pulse-feed-action-btn {
  background: var(--color-fg-default);
  color: var(--color-canvas-default);
  padding: 8px 16px;
  border: 1px solid var(--color-border-default);
  font-size: 13px;
}
```

#### Disabled State
```css
.pulse-feed-action-btn-disabled {
  background: var(--color-canvas-default);
  color: var(--color-fg-muted);
  cursor: not-allowed;
}
```

### Cards (Feed Items)

```css
.pulse-feed-item {
  border: 1px solid var(--color-border-default);
  background: var(--color-canvas-default);
  margin-bottom: 16px;
}

.pulse-feed-item-header {
  padding: 12px 16px;
  border-bottom: 1px solid var(--color-border-default);
}

.pulse-feed-item-body {
  padding: 16px;
}

.pulse-feed-item-footer {
  padding: 12px 16px;
  border-top: 1px solid var(--color-border-default);
}
```

#### Closed State (Decisions/Commitments)
```css
.pulse-feed-item-closed {
  opacity: 0.7;
  border-color: var(--color-border-muted);
}

.pulse-feed-item-closed .pulse-feed-item-header {
  background: var(--color-canvas-subtle);
}
```

### Avatars

```css
.pulse-avatar {
  width: 32px;
  height: 32px;
  border: 2px solid var(--color-canvas-default);
  border-radius: 50%;
  background: var(--color-neutral-muted);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  font-weight: 500;
}
```

For stacked avatars:
```css
.pulse-avatar + .pulse-avatar {
  margin-left: -8px;
}
```

### Navigation Items

```css
.pulse-nav-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 12px;
  font-size: 14px;
  background: transparent;
  border: none;
  width: 100%;
  cursor: pointer;
}

.pulse-nav-item:hover,
.pulse-nav-item.active {
  background: var(--color-fg-default);
  color: var(--color-canvas-default);
}
```

### Progress Bars

```css
.pulse-progress-bar {
  height: 8px;
  background: var(--color-canvas-default);
  border: 1px solid var(--color-border-default);
}

.pulse-progress-fill {
  height: 100%;
  background: var(--color-success-emphasis);
}
```

---

## Icons

The Pulse design uses:
1. **Octicons** - GitHub's icon set via the `octicon` helper
2. **Custom SVG icons** - Resource type icons in `/public/resource-icons/`

### Resource Icons
- `/resource-icons/note-icon.svg`
- `/resource-icons/decision-icon.svg`
- `/resource-icons/commitment-icon.svg`

### Common Octicons
- `heart-fill` - Heartbeat indicator
- `comment` - Comments
- `lock` / `eye` - Visibility (private/public)
- `gear` - Settings
- `person-add` - Invite
- `chevron-left` / `chevron-right` - Navigation
- `book` - Read confirmation
- `check-circle` - Vote/complete
- `person` - Join commitment

---

## Dark Mode

Dark mode is automatic based on system preference:

```css
@media (prefers-color-scheme: dark) {
  :root {
    /* All color variables are redefined for dark mode */
  }
}
```

No manual toggle - respects `prefers-color-scheme` media query.

---

## Responsive Breakpoints

### Mobile (≤768px)
```css
@media (max-width: 768px) {
  .pulse-container {
    flex-direction: column;
  }

  .pulse-sidebar {
    width: 100%;
    border-right: none;
    border-bottom: 1px solid var(--color-border-default);
  }

  .pulse-nav {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }

  .pulse-motto-footer::before {
    display: none; /* Hide sidebar border continuation */
  }
}
```

---

## File Organization

```
app/assets/stylesheets/
├── root_variables.css      # Shared color tokens (light/dark)
├── studio_pulse.css        # Pulse-specific component styles
├── application.css         # Legacy application styles
└── ...
```

---

## Usage Examples

### Adding a New Pulse Page

1. Set layout in controller:
```ruby
class MyController < ApplicationController
  layout "pulse"
end
```

2. Use Pulse CSS classes in view:
```erb
<div class="pulse-feed">
  <article class="pulse-feed-item">
    <div class="pulse-feed-item-header">...</div>
    <div class="pulse-feed-item-body">...</div>
    <div class="pulse-feed-item-footer">...</div>
  </article>
</div>
```

### Creating a New Component

1. Add styles to `studio_pulse.css` using shared color variables
2. Use the `pulse-` prefix for all class names
3. Include hover and dark mode states via CSS variables
4. Test at 768px breakpoint for mobile

---

## Migration Notes

When migrating existing pages to Pulse:
1. Change layout to `pulse`
2. Replace `markdown-body` wrapper with Pulse structure
3. Update CSS classes to use `pulse-` prefixed versions
4. Ensure all colors use `--color-*` variables (not hardcoded)
5. Test light mode, dark mode, and mobile responsiveness
