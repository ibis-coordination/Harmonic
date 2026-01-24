# Pulse Design System Migration Plan

## Goal
Generalize the Pulse design system into a style guide and UI component library, create mockups for Pulse versions of remaining pages, and update all pages to use the Pulse design.

## Current State

### Already Complete
- **Studio Pulse page** (`/studios/:handle/pulse`) - New studio homepage with activity feed, sidebar, cycle navigation, heartbeats
- This IS the new studio homepage - just need to update routes

### Views Remaining (138 total)
| Category | Count | Current Layout |
|----------|-------|----------------|
| Studios (non-pulse) | 13 | application |
| Notes | 9 | application |
| Decisions | 9 | application |
| Commitments | 10 | application |
| Users | 7 | application |
| Cycles | 5 | application |
| Admin | 10 | application |
| Auth/Public | 14+ | application |
| Shared partials | ~45 | - |

### Current Styling Architecture
- `root_variables.css` - `--color-*` variables (11 vars)
- `application.css` - Main app (1,113 lines)
- `studio_pulse.css` - Pulse styles with `--pulse-color-*` (1,304 lines)

### Key Differences to Resolve
| Aspect | Main App | Pulse |
|--------|----------|-------|
| Layout | Centered `markdown-body` | Sidebar + main content |
| Colors | `--color-*` | `--pulse-color-*` |
| Navigation | Top bar only | Sidebar with sections |
| Components | Ad-hoc styling | Consistent card patterns |

---

## Phase 1: Route Update & Style Guide

### 1.1 Make Pulse the Studio Homepage
Update routes so `/studios/:handle` points to Pulse:
- Modify `config/routes.rb` to make Pulse the default
- Update `StudiosController` or redirect to Pulse
- Keep settings/invite/join as separate pages using Pulse layout

### 1.2 Unify Color System
Consolidate to single `--color-*` namespace in `root_variables.css`:
- Add missing success colors from Pulse
- Create migration aliases in `studio_pulse.css`

### 1.3 Create Style Guide Document
Location: `/docs/PULSE_STYLE_GUIDE.md`

Contents:
- Color tokens (unified system)
- Typography scales
- Spacing system (4px/8px grid)
- Component patterns with examples
- Layout variants (sidebar, no-sidebar)
- Dark mode notes
- Responsive breakpoints (768px)

**Files:**
- `config/routes.rb`
- `app/controllers/studios_controller.rb`
- `app/assets/stylesheets/root_variables.css`
- `app/assets/stylesheets/studio_pulse.css`

---

## Phase 2: Component Library

### 2.1 Modular CSS Structure
Create `/app/assets/stylesheets/pulse/` directory:
```
pulse/
  _variables.css      # Unified tokens
  _reset.css          # Box-sizing, defaults
  _typography.css     # Fonts, headings
  _buttons.css        # Button variants
  _forms.css          # Inputs, selects
  _cards.css          # Feed items, content cards
  _avatars.css        # User avatars
  _navigation.css     # Sidebar nav, breadcrumbs
  _layout.css         # Container, sidebar, main
```

### 2.2 Unified Layout
Extend `pulse.html.erb` to support different sidebar modes:
- Full sidebar (studio context with cycle, heartbeats, nav)
- Modified sidebar (resource detail with studio context)
- Minimal sidebar (user/admin navigation only)
- No sidebar (auth pages, centered forms)

### 2.3 Shared Partials (Pulse Variants)
Create Pulse versions of key shared partials:

| Original | Pulse Variant |
|----------|---------------|
| `_more_button.html.erb` | `_pulse_more_button.html.erb` |
| `_collapseable_section.html.erb` | `_pulse_accordion.html.erb` |
| `_inline_resource_item.html.erb` | `_pulse_resource_link.html.erb` |
| `_comments_section.html.erb` | `_pulse_comments.html.erb` |
| `_attachments_section.html.erb` | `_pulse_attachments.html.erb` |
| `_created_by.html.erb` | `_pulse_author.html.erb` |

**Files:**
- `app/views/layouts/pulse.html.erb`
- `app/views/pulse/_sidebar.html.erb`
- `app/views/shared/` (new Pulse partials)

---

## Phase 3: Page Mockups

### 3.1 Mockup Format
**HTML files** in `/docs/mockups/pulse/`:
- Static HTML using Pulse CSS
- Viewable directly in browser
- Include both light and dark mode examples

### 3.2 Priority Pages for Mockups

**Tier 1 - Content Detail Pages:**
1. Note show page
2. Decision show page
3. Commitment show page
4. Note new/edit forms
5. Decision new/edit forms

**Tier 2 - Studio Supporting Pages:**
6. Studio settings
7. Team/members page
8. Cycles index/show
9. Backlinks page

**Tier 3 - User Context:**
10. User profile
11. User settings
12. Notifications

**Tier 4 - Admin/Auth:**
13. Admin dashboard
14. Login/signup pages

---

## Phase 4: Page Implementation

### Implementation Order
1. **Sprint 1:** Studio supporting pages (settings, team, invite)
2. **Sprint 2:** Note, Decision, Commitment show pages
3. **Sprint 3:** Note, Decision, Commitment new/edit pages
4. **Sprint 4:** User pages (profile, settings, notifications)
5. **Sprint 5:** Admin and auth pages

### Migration Pattern Per Page
1. Update controller: `layout 'pulse'`
2. Replace `markdown-body` wrapper with Pulse structure
3. Use Pulse component partials
4. Apply Pulse CSS classes
5. Test light/dark mode, mobile responsiveness

### Sidebar Configurations
| Page Type | Sidebar Mode |
|-----------|--------------|
| Studio Pulse | Full (cycle, heartbeats, nav, pinned, links) |
| Studio Settings/Team | Modified (studio info, nav links) |
| Resource Detail | Modified (parent studio context, quick actions) |
| User Pages | Minimal (user info, navigation) |
| Admin Pages | Minimal (admin navigation) |
| Auth Pages | None (centered form) |

---

## Phase 5: Cleanup & Testing

### Testing Strategy
- Visual review: light/dark mode, mobile/desktop
- Functional: Stimulus controllers, form submissions, Turbo navigation
- E2E: Update Playwright tests for new selectors

### Cleanup Tasks
- Remove `--pulse-color-*` aliases (use unified `--color-*`)
- Consolidate duplicate partials
- Archive old `application.css` styles
- Deprecate `application.html.erb` layout
- Update documentation

---

## Verification Checklist

After each phase:
- [ ] Existing E2E tests pass
- [ ] Manual visual review
- [ ] Dark mode works
- [ ] Mobile responsive
- [ ] No console errors
- [ ] Performance maintained

---

## Summary

1. **Phase 1:** Update routes to make Pulse the studio homepage, unify colors, create style guide
2. **Phase 2:** Build modular CSS component library, extend Pulse layout for different contexts
3. **Phase 3:** Create HTML mockups for remaining pages
4. **Phase 4:** Implement pages (Studio support → Content → Users → Admin)
5. **Phase 5:** Testing and cleanup

The Pulse studio page is already complete - this plan focuses on extending that design to all other pages.
