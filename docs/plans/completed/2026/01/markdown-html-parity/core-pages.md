# Core Pages - Functional Gaps

This document covers missing **actions and capabilities** on the main content pages.

[← Back to Index](INDEX.md)

---

## Home Page (`/`)

### Missing Actions

| Action | HTML Capability | Markdown Status |
|--------|-----------------|-----------------|
| Navigate to scenes | "Explore other scenes" link, scene list | No scenes section |
| Create new scene | "New Scene" button | No action available |

### Notes
- Scenes section is entirely missing - users can't see or navigate to their scenes
- Heartbeat indicators are display-only (heartbeat actions work via studio pages)

---

## Studio Page (`/studios/:handle`)

### Missing Actions

| Action | HTML Capability | Markdown Status |
|--------|-----------------|-----------------|
| `invite_member()` | "Invite" button for permitted users | Missing |

### Notes
- Current cycle content (notes/decisions/commitments) accessible via `/cycles` navigation
- Heartbeat actions work via the heartbeat gate mechanism
- Settings accessible via `/settings` path

---

## Note Page (`/studios/:handle/n/:id`)

### Missing Actions

None on show page - pin/unpin actions belong on settings page.

### Notes
- Edit functionality exists at `/n/:id/edit`
- Attachments not displayed, but this is display-only (files are there)

---

## Decision Page (`/studios/:handle/d/:id`)

### Missing Actions

None on show page - pin/unpin/duplicate actions belong on settings page.

### Notes
- Voting works via `vote()` action - text-based is appropriate for markdown
- Settings accessible via `/settings` path

---

## Commitment Page (`/studios/:handle/c/:id`)

### Missing Actions

None on show page - pin/unpin actions belong on settings page.

### Notes
- Join/leave works via existing actions
- Settings accessible via `/settings` path

---

## Cycle Page (`/studios/:handle/cycles/:cycle`)

### Missing Actions

None identified. Cycle pages are primarily for viewing content, and all navigation to contained items works.

### Notes
- Sync/refresh is a UI convenience, not a functional gap
- Collapsible sections are display-only

---

## Summary: Core Page Actions Needed

| Action | Pages | Priority | Location |
|--------|-------|----------|----------|
| `pin_item()` | Note, Decision, Commitment | High | Settings page |
| `unpin_item()` | Note, Decision, Commitment | High | Settings page |
| `duplicate_decision()` | Decision | Medium | Settings page |
| `invite_member()` | Studio | Medium | Studio page |
| Navigate to scenes | Home | Medium | Home page |
| `create_scene()` | Home (or /scenes/new) | Medium | /scenes/new |
