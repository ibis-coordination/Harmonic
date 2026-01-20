# V2 React + Effect.js UI Implementation Plan

## Overview

Add a parallel v2 UI built with React and Effect.js alongside the existing v1 Hotwire UI. Users can toggle between versions via a preference setting. The v2 UI will enable richer interactivity, complex state management, and real-time collaboration features that are challenging with the current Hotwire stack.

## Goals

- **Complex state management**: Optimistic updates, undo/redo, cross-component state
- **Rich interactions**: Drag-and-drop, animations, gestures
- **Real-time collaboration**: Live cursors, presence indicators, concurrent editing (future)
- **Type-safe architecture**: Effect.js for error handling and structured concurrency

## Tech Stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Build | **Vite** | Fast HMR, modern ESM, excellent DX |
| Framework | **React 18** | Component model, ecosystem, concurrent features |
| Routing | **TanStack Router** | Type-safe routes, integrates with TanStack Query |
| Server State | **TanStack Query** | Caching, optimistic updates, background sync |
| Client State | **Zustand** | Lightweight, works well with Effect |
| Business Logic | **Effect.js** | Typed errors, structured concurrency, dependency injection |
| Styling | **Tailwind CSS** | Already in Rails app, consistent design tokens |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Browser                              │
├─────────────────────────────────────────────────────────┤
│  User Preference: ui_version = "v1" | "v2"              │
├─────────────────┬───────────────────────────────────────┤
│     v1 (Hotwire)│           v2 (React + Effect)         │
│  ┌─────────────┐│  ┌─────────────────────────────────┐  │
│  │ Turbo Drive ││  │ TanStack Router                 │  │
│  │ Turbo Frames││  │ TanStack Query ←→ /api/v1/*    │  │
│  │ Stimulus    ││  │ Zustand (client state)          │  │
│  │ .html.erb   ││  │ Effect.js (business logic)      │  │
│  └─────────────┘│  └─────────────────────────────────┘  │
├─────────────────┴───────────────────────────────────────┤
│                   Rails Backend                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ ApplicationController (format negotiation)          │ │
│  │ ApiHelper (shared business logic)                   │ │
│  │ /api/v1/* (JSON endpoints)                         │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Project Structure

```
Harmonic/
├── client/                      # NEW: React v2 app
│   ├── package.json
│   ├── vite.config.ts
│   ├── tsconfig.json
│   ├── index.html               # Entry point (dev server)
│   ├── src/
│   │   ├── main.tsx             # React entry
│   │   ├── App.tsx              # Root component
│   │   ├── routes/              # TanStack Router routes
│   │   │   ├── __root.tsx       # Root layout
│   │   │   ├── studios/
│   │   │   │   ├── $handle.tsx  # Studio layout
│   │   │   │   ├── n.$id.tsx    # Note detail
│   │   │   │   ├── d.$id.tsx    # Decision detail
│   │   │   │   └── c.$id.tsx    # Commitment detail
│   │   ├── components/          # UI components
│   │   ├── services/            # Effect.js services
│   │   │   ├── api.ts           # API client (Effect-based)
│   │   │   ├── auth.ts          # Auth service
│   │   │   └── realtime.ts      # WebSocket/SSE (future)
│   │   ├── stores/              # Zustand stores
│   │   ├── hooks/               # React hooks
│   │   └── lib/                 # Utilities
│   └── tests/                   # Vitest tests
├── app/
│   ├── views/
│   │   └── layouts/
│   │       └── v2.html.erb      # NEW: Minimal shell for React
│   └── ...
└── ...
```

## Implementation Phases

### Phase 1: Foundation (This Plan)

Set up the infrastructure to serve a React app alongside Rails:

1. **Create client/ directory with Vite + React + TypeScript**
   - Initialize package.json with dependencies
   - Configure Vite for development and production builds
   - Set up TypeScript with strict mode

2. **Add Effect.js and establish patterns**
   - Create base API client using Effect
   - Define error types and handlers
   - Set up service layer architecture

3. **Configure TanStack Router and Query**
   - Define route tree matching Rails routes
   - Configure query client with defaults
   - Create initial route loaders

4. **Add user preference for UI version**
   - Add `ui_version` column to users table
   - Add preference toggle endpoint
   - Store preference in session/cookie for non-authenticated pages

5. **Rails integration**
   - Create v2.html.erb layout (minimal shell that mounts React)
   - Modify ApplicationController to check ui_version preference
   - Configure asset pipeline to serve Vite builds in production
   - Proxy Vite dev server in development

6. **Build app shell**
   - Navigation header
   - Studio selector
   - Basic routing between major sections

### Phase 2: Core Features (Future)

- Note viewing and creation
- Decision viewing and voting
- Commitment viewing and joining
- Cycle navigation

### Phase 3: Rich Interactions (Future)

- Drag-and-drop for pinning
- Optimistic updates
- Undo/redo

### Phase 4: Real-time (Future)

- Presence indicators
- Live updates
- Collaborative editing

## Key Files to Modify

### Rails Backend

| File | Change |
|------|--------|
| `db/migrate/xxx_add_ui_version_to_users.rb` | Add ui_version column |
| `app/models/user.rb` | Add ui_version enum/accessor |
| `app/controllers/application_controller.rb` | Check ui_version, render v2 layout |
| `app/views/layouts/v2.html.erb` | New minimal layout for React mount |
| `config/routes.rb` | Add route for UI preference toggle |

### New Files (client/)

| File | Purpose |
|------|---------|
| `client/package.json` | Dependencies and scripts |
| `client/vite.config.ts` | Vite configuration |
| `client/tsconfig.json` | TypeScript configuration |
| `client/src/main.tsx` | React entry point |
| `client/src/App.tsx` | Root component with providers |
| `client/src/services/api.ts` | Effect-based API client |

## Feature Flag / User Preference Flow

```
1. User visits /studios/team
2. ApplicationController#before_action checks current_user.ui_version
3. If ui_version == "v2":
   - Render layouts/v2.html.erb (React shell)
   - React app hydrates and takes over routing
   - API calls go to /api/v1/*
4. If ui_version == "v1" (default):
   - Normal Hotwire flow unchanged
```

## Development Workflow

```bash
# Terminal 1: Rails server (existing)
./scripts/start.sh

# Terminal 2: Vite dev server (new)
cd client && npm run dev
```

In development, Rails proxies requests to Vite dev server for hot module replacement. In production, Vite builds to `public/v2/` and Rails serves static assets.

## Verification

After Phase 1 implementation:

1. **User preference works**: Toggle between v1/v2 in settings
2. **React app loads**: Navigate to any page with v2 enabled
3. **Routing works**: Client-side navigation between /studios/:handle, /n/:id, etc.
4. **API integration**: React app fetches data from /api/v1/*
5. **Hot reload**: Changes to React components update without full refresh
6. **Production build**: `cd client && npm run build` produces working bundle

## Open Questions for Later

- WebSocket vs SSE for real-time updates
- Shared component library between v1 and v2
- Gradual migration strategy for complex features
- Mobile-specific considerations
