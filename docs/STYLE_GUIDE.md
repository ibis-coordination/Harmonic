# Harmonic Style Guide (Pulse Design System)

The Pulse design system provides the UI layer for Harmonic. All pages use `layout "pulse"`.

**Live reference:** Visit `/dev/styleguide` in development to see all components rendered with current styles. That page is the source of truth for how components look — this document covers structure, conventions, and where to find things.

**Static analysis:** Run `./scripts/check-style-guide.sh` to check for violations. This runs automatically in pre-commit hooks.

## Color Tokens

Defined in `app/assets/stylesheets/root_variables.css`. Light/dark mode adapts automatically via `prefers-color-scheme` — no manual toggle.

Key token families: `--color-fg-*` (text), `--color-canvas-*` (backgrounds), `--color-border-*` (borders), `--color-accent-*` (interactive), `--color-danger-*` / `--color-success-*` / `--color-attention-*` (status), `--color-neutral-*` (utility). Always use these variables — never hardcode colors.

## Typography

**Font stack:** `-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif`
**Monospace:** `"Source Code Pro", "Lucida Console", monospace`
**Line height:** 1.5

| Element | Size | Weight |
|---------|------|--------|
| Page title | 20px | 600 |
| Body text | 14px | 400 |
| Tiny text | 13px | 400 |
| Small text | 12px | 400 |
| Section label | 11px | 400, uppercase, letter-spacing: 0.5px |

## Spacing

4px grid with common increments of 8px: `4 / 6 / 8 / 12 / 16 / 24px`.

Key values: sidebar sections 16px, feed items 16px horizontal / 12px vertical, buttons 8px 16px, content max-width `min(88vw, 800px)`, form inputs max 600px.

## Layout

```
┌─────────────────────────────────────────────────┐
│  Header (56px)                                  │
├──────────────┬──────────────────────────────────┤
│  Sidebar     │  Main Content                    │
│  (280px)     │  (flex: 1)                       │
├──────────────┴──────────────────────────────────┤
│  Footer (motto)                                 │
└─────────────────────────────────────────────────┘
```

### Sidebar Modes

Set `@sidebar_mode` in the controller:

| Mode | Partial | Use Case |
|------|---------|----------|
| `full` (default) | `pulse/sidebar` | Studio page — cycle, heartbeats, nav, pinned items |
| `resource` | `pulse/sidebar_resource` | Note/Decision/Commitment detail pages |
| `minimal` | `pulse/sidebar_minimal` | User profile, settings, notifications |
| `none` | (no sidebar) | Auth pages, centered forms |

### Key CSS Classes

- `.pulse-container` / `.pulse-container.no-sidebar` — main wrapper
- `.pulse-sidebar` with `[data-mode="resource"|"minimal"]` — sidebar variants
- `.pulse-main` — main content area
- `.pulse-feed-item` with `-header` / `-body` / `-footer` — feed cards
- `.pulse-action-btn` / `.pulse-feed-action-btn` — buttons
- `.pulse-avatar` — 32px circular avatars (stack with negative margin)
- `.pulse-nav-item` — sidebar navigation links
- `.pulse-progress-bar` / `.pulse-progress-fill` — progress indicators

## Icons

Uses [GitHub Octicons](https://primer.style/octicons/) via `octicon` helper, plus custom SVGs in `/public/resource-icons/` for note, decision, and commitment icons.

Sizes: 16px (inline default), 22-24px (medium), 31-36px (large).

## Naming Conventions

- **New classes must use the `pulse-` prefix** (e.g., `.pulse-feed-item`). Enforced by `check-style-guide.sh`.
- Other components: `.component-name`, `.component-element`, `.component-state`
- Resource types: `.note-icon`, `.resource-link-note`, etc.

## Responsive

Mobile breakpoint at 768px: sidebar collapses to full-width horizontal layout. Styles live in `pulse/_responsive.css`.

## File Organization

```
app/assets/stylesheets/
├── root_variables.css          # Color tokens (light/dark)
├── pulse.css                   # Manifest importing modular components
├── pulse/
│   ├── _base.css               # Reset, typography, links, tooltips
│   ├── _layout.css             # Container, sidebar, main, header, footer
│   ├── _components.css         # Buttons, avatars, progress bars
│   ├── _sidebar.css            # Cycle, heartbeat, nav, pinned, links
│   ├── _feed.css               # Feed items, action buttons, cards
│   ├── _heartbeat.css          # Heartbeat section, animations
│   └── _responsive.css         # Mobile breakpoints
└── application.css             # Legacy styles
```

Key view directories: `app/views/pulse/` (layout partials, feed items), `app/views/shared/` (reusable partials like `_pulse_author`, `_pulse_comments`, `_pulse_accordion`, `_pulse_breadcrumb`).

## Adding a New Page

1. Set `layout "pulse"` in the controller
2. Set `@sidebar_mode` if not using the default full sidebar
3. Use `pulse-` prefixed CSS classes and `--color-*` variables
4. Add styles to the appropriate file in `pulse/` (components, feed, sidebar, or layout)
5. Test light mode, dark mode, and the 768px mobile breakpoint
6. Check the live style guide at `/dev/styleguide` for reference

## Migrating an Existing Page

1. Change layout to `pulse`
2. Replace `markdown-body` wrapper with Pulse structure
3. Update CSS classes to `pulse-` prefixed versions
4. Replace hardcoded colors with `--color-*` variables
5. Test light/dark mode and mobile
