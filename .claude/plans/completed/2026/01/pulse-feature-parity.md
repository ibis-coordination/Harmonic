# Pulse Page Feature Parity Plan

## Goal
Bring the Pulse page to feature parity with the classic studio homepage, and generalize it to work for all superagent types (studios and scenes).

## Status: COMPLETE ✓

All phases have been implemented. The Pulse page now has full feature parity with the classic view.

---

## Phase 1: Layout Parity with Application Layout ✓

### 1.1 Top Navigation Bar ✓
- Harmonic logo and brand name (top-left)
- "+ New" action button
- Notification badge + user menu (top-right)

### 1.2 Flash Messages ✓
- Dismissable notice/alert banners with styling

### 1.3 Session Banners ✓
- Subagent impersonation session banner
- Representation session banner

### 1.4 Site Motto Footer ✓
- "Do the right thing. ❤️" with link to `/motto`
- Sidebar border continues through footer via pseudo-element

---

## Phase 2: Generalize for All Superagents ✓

### 2.1 Studio + Scene Support ✓
- Controller allows both "studio" and "scene" superagent types

### 2.2 Dynamic Terminology ✓
- Breadcrumb shows "Studio" or "Scene" based on type
- Visibility icons differ (lock for studio, eye for scene)

### 2.3 Routes Verified ✓
- Pulse route works for both `/studios/:handle/pulse` and `/scenes/:handle/pulse`

---

## Phase 3: Sidebar Features ✓

### 3.1 Superagent Profile Image ✓
### 3.2 Breadcrumb (tenant / type) ✓
### 3.3 Settings Link (admin only) ✓
### 3.4 Representation Link ✓
### 3.5 Explore Links (Cycles, Backlinks) ✓
### 3.6 Pinned Items Section ✓
### 3.7 Invite Member Button ✓

---

## Phase 4: Visual Polish ✓

### 4.1 Status Differentiation ✓
- Closed decisions/commitments have reduced opacity (0.7)
- Muted border color for closed items
- Subtle header background for closed items

### 4.2 Progress Bars ✓
- Cycle progress bar uses green (`--pulse-color-success-emphasis`)
- Commitment progress bar uses green

### 4.3 Comment Display ✓
- Notes that are comments show "Comment" label instead of "Note"
- Comment octicon instead of note icon

### 4.4 Layout Fixes ✓
- Body uses flex column with min-height: 100vh
- Container uses flex: 1 to fill space
- Sidebar border extends to page bottom via footer pseudo-element
- Removed "Classic view" link (Pulse is the primary view)

---

## Verification Checklist

- [x] Pulse page loads for studios (`/studios/:handle/pulse`)
- [x] Pulse page loads for scenes (`/scenes/:handle/pulse`)
- [x] Top nav shows notifications badge and user menu
- [x] Flash messages display correctly
- [x] Session banners appear when in impersonation/representation mode
- [x] Motto footer displays at bottom
- [x] Superagent image displays in sidebar
- [x] Settings link appears for admins only
- [x] Representation link works
- [x] Cycles and Backlinks links work
- [x] Pinned items show when present
- [x] Invite button appears for users with invite permission
- [x] All features work on both studios and scenes
- [x] Closed items visually differentiated from open items
- [x] Progress bars use success color
- [x] Comments display distinctly from notes
- [x] Sidebar border extends full page height
