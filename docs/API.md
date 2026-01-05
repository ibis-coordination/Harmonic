# Harmonic API Documentation

REST API for programmatic access to Harmonic data and functionality.

## Overview

The Harmonic API provides JSON endpoints for managing notes, decisions, commitments, cycles, users, and studios. The API is designed for automation and integration with external tools.

**Base URL**: `https://{tenant}.{domain}/api/v1`

**Studio-scoped URL**: `https://{tenant}.{domain}/studios/{studio_handle}/api/v1`

## Authentication

All API requests require a Bearer token in the Authorization header:

```
Authorization: Bearer {api_token}
```

### Obtaining a Token

Tokens are created through the web UI at `/u/{handle}/settings/tokens` or via the API if you already have a token with `create:api_tokens` scope.

### Token Scopes

Tokens have scopes that control access:

| Scope | Description |
|-------|-------------|
| `read:all` | Read access to all resources |
| `create:all` | Create new resources |
| `update:all` | Update existing resources |
| `delete:all` | Delete resources |

Granular scopes are also available (e.g., `read:notes`, `create:decisions`).

### Token Expiration

Tokens expire after 1 year by default. The `expires_at` field can be customized when creating a token.

## Request Format

- **Content-Type**: `application/json`
- **Accept**: `application/json` or `text/markdown`

All request bodies should be JSON. The API also supports Markdown responses for LLM consumption when `Accept: text/markdown` is set.

## Response Format

All responses are JSON objects. Successful responses return the resource or an array of resources. Error responses have this format:

```json
{
  "error": "Error message describing what went wrong"
}
```

### Common HTTP Status Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 400 | Bad request (validation error) |
| 401 | Unauthorized (invalid or expired token) |
| 403 | Forbidden (insufficient permissions or API not enabled) |
| 404 | Not found |

## Include Parameter

Many endpoints support an `include` query parameter to embed related resources:

```
GET /api/v1/decisions/abc123?include=options,participants,results
```

---

## Endpoints

### API Info

#### GET /api/v1

Returns API metadata and available routes.

**Response:**
```json
{
  "name": "Harmonic Team API",
  "version": "1.0.0",
  "routes": [
    { "path": "/api/v1/decisions/:decision_id", "methods": ["GET", "PUT", "DELETE"] },
    ...
  ]
}
```

---

### Cycles

Cycles are time-bounded activity windows. They are computed, not stored in the database.

#### GET /api/v1/cycles

List available cycles.

**Response:**
```json
[
  {
    "name": "today",
    "display_name": "Today",
    "time_window": "Jan 5, 2026",
    "unit": "day",
    "start_date": "2026-01-05T00:00:00Z",
    "end_date": "2026-01-05T23:59:59Z",
    "counts": { "notes": 5, "decisions": 2, "commitments": 1 }
  },
  ...
]
```

**Query Parameters:**
- `include` - Comma-separated: `notes`, `decisions`, `commitments`, `backlinks`
- `filters` - Filter content (implementation specific)
- `sort_by` - Sort order

#### GET /api/v1/cycles/{name}

Get a specific cycle with all content.

**Path Parameters:**
- `name` - Cycle name: `today`, `yesterday`, `this-week`, `last-week`, `this-month`, `last-month`, `this-year`, `last-year`

**Response:**
```json
{
  "name": "today",
  "display_name": "Today",
  "time_window": "Jan 5, 2026",
  "unit": "day",
  "start_date": "2026-01-05T00:00:00Z",
  "end_date": "2026-01-05T23:59:59Z",
  "counts": { "notes": 5, "decisions": 2, "commitments": 1 },
  "notes": [...],
  "decisions": [...],
  "commitments": [...],
  "backlinks": [...]
}
```

---

### Notes

Notes are posts/content items (maps to "Observe" in OODA).

#### GET /api/v1/notes/{id}

Get a specific note.

**Response:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "truncated_id": "550e8400",
  "title": "Note Title",
  "text": "Note content in markdown...",
  "deadline": "2026-01-10T00:00:00Z",
  "confirmed_reads": 5,
  "created_at": "2026-01-05T10:00:00Z",
  "updated_at": "2026-01-05T10:00:00Z",
  "created_by_id": "user-uuid",
  "updated_by_id": "user-uuid",
  "commentable_type": null,
  "commentable_id": null
}
```

**Include options:** `history_events`, `backlinks`

#### POST /api/v1/notes

Create a new note.

**Request Body:**
```json
{
  "title": "Note Title",
  "text": "Note content in markdown...",
  "deadline": "2026-01-10T00:00:00Z"
}
```

**Required:** `text` (title is derived from first line if not provided)

#### PUT /api/v1/notes/{id}

Update a note.

**Request Body:**
```json
{
  "title": "Updated Title",
  "text": "Updated content...",
  "deadline": "2026-01-15T00:00:00Z"
}
```

#### POST /api/v1/notes/{id}/confirm

Confirm read on a note. Creates a history event recording that the current user has read the note.

**Response:**
```json
{
  "id": "event-uuid",
  "note_id": "note-uuid",
  "user_id": "user-uuid",
  "event_type": "read_confirmation",
  "happened_at": "2026-01-05T12:00:00Z"
}
```

---

### Decisions

Decisions use acceptance voting for group consensus (maps to "Decide" in OODA).

#### GET /api/v1/decisions/{id}

Get a specific decision.

**Response:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "truncated_id": "550e8400",
  "question": "What should we do?",
  "description": "Additional context...",
  "options_open": true,
  "deadline": "2026-01-10T00:00:00Z",
  "voter_count": 5,
  "created_at": "2026-01-05T10:00:00Z",
  "updated_at": "2026-01-05T10:00:00Z"
}
```

**Include options:** `participants`, `options`, `approvals`, `results`, `backlinks`

#### POST /api/v1/decisions

Create a new decision.

**Request Body:**
```json
{
  "question": "What should we do?",
  "description": "Additional context...",
  "deadline": "2026-01-10T00:00:00Z",
  "options_open": true,
  "options": [
    { "title": "Option A", "description": "Details..." },
    { "title": "Option B", "description": "Details..." }
  ]
}
```

**Required:** `question`, `deadline`

#### PUT /api/v1/decisions/{id}

Update a decision. Only the creator can update.

**Request Body:**
```json
{
  "question": "Updated question?",
  "description": "Updated context...",
  "options_open": false,
  "deadline": "2026-01-15T00:00:00Z"
}
```

---

### Decision Options

Options are choices within a decision.

#### GET /api/v1/decisions/{decision_id}/options

List options for a decision.

#### POST /api/v1/decisions/{decision_id}/options

Add an option to a decision. Requires `options_open` to be true (or user is creator).

**Request Body:**
```json
{
  "title": "New Option",
  "description": "Option details..."
}
```

#### PUT /api/v1/decisions/{decision_id}/options/{id}

Update an option.

#### DELETE /api/v1/decisions/{decision_id}/options/{id}

Delete an option. Only allowed if no votes have been cast on it.

---

### Approvals (Votes)

Approvals represent votes on decision options.

#### GET /api/v1/decisions/{decision_id}/approvals

List all approvals for a decision.

#### GET /api/v1/decisions/{decision_id}/options/{option_id}/approvals

List approvals for a specific option.

#### POST /api/v1/decisions/{decision_id}/options/{option_id}/approvals

Cast a vote on an option.

**Request Body:**
```json
{
  "value": 1,
  "stars": 0
}
```

**Fields:**
- `value` - 0 (reject) or 1 (accept)
- `stars` - 0 or 1 (preference indicator)

**Response:**
```json
{
  "id": "approval-uuid",
  "option_id": "option-uuid",
  "decision_id": "decision-uuid",
  "decision_participant_id": "participant-uuid",
  "value": 1,
  "stars": 0,
  "created_at": "2026-01-05T12:00:00Z",
  "updated_at": "2026-01-05T12:00:00Z"
}
```

#### PUT /api/v1/decisions/{decision_id}/options/{option_id}/approvals/{id}

Update a vote.

---

### Decision Participants

Participants are users who have interacted with a decision.

#### GET /api/v1/decisions/{decision_id}/participants

List participants in a decision.

**Response:**
```json
[
  {
    "id": "participant-uuid",
    "decision_id": "decision-uuid",
    "user_id": "user-uuid",
    "created_at": "2026-01-05T10:00:00Z"
  }
]
```

**Include options:** `approvals`

---

### Decision Results

Results show the current voting outcome.

#### GET /api/v1/decisions/{decision_id}/results

Get voting results for a decision.

**Response:**
```json
[
  {
    "position": 1,
    "decision_id": "decision-uuid",
    "option_id": "option-uuid",
    "option_title": "Winning Option",
    "option_random_id": "123456789",
    "approved_yes": 5,
    "approved_no": 1,
    "approval_count": 6,
    "stars": 3
  },
  ...
]
```

Results are sorted by: `approved_yes` (desc), then `stars` (desc), then `random_id` (for ties).

---

### Commitments

Commitments are action pledges with critical mass thresholds (maps to "Act" in OODA).

#### GET /api/v1/commitments/{id}

Get a specific commitment.

**Response:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "truncated_id": "550e8400",
  "title": "Commitment Title",
  "description": "What we're committing to...",
  "deadline": "2026-01-10T00:00:00Z",
  "critical_mass": 10,
  "participant_count": 7,
  "created_at": "2026-01-05T10:00:00Z",
  "updated_at": "2026-01-05T10:00:00Z",
  "created_by_id": "user-uuid",
  "updated_by_id": "user-uuid"
}
```

**Include options:** `participants`, `backlinks`

#### POST /api/v1/commitments

Create a new commitment.

**Request Body:**
```json
{
  "title": "Commitment Title",
  "description": "What we're committing to...",
  "deadline": "2026-01-10T00:00:00Z",
  "critical_mass": 10
}
```

**Required:** `title`, `deadline`, `critical_mass`

#### PUT /api/v1/commitments/{id}

Update a commitment. Only the creator can update.

**Request Body:**
```json
{
  "title": "Updated Title",
  "description": "Updated description...",
  "deadline": "2026-01-15T00:00:00Z",
  "critical_mass": 15
}
```

#### POST /api/v1/commitments/{id}/join

Join a commitment.

**Request Body:**
```json
{
  "committed": true
}
```

---

### Commitment Participants

#### GET /api/v1/commitments/{commitment_id}/participants

List participants in a commitment.

---

### Studios

Studios are private groups within a tenant.

#### GET /api/v1/studios

List studios the current user is a member of.

**Response:**
```json
[
  {
    "id": "studio-uuid",
    "name": "My Studio",
    "handle": "my-studio",
    "timezone": "America/New_York",
    "tempo": "weekly"
  }
]
```

#### GET /api/v1/studios/{id}

Get a specific studio. Can use ID or handle.

#### POST /api/v1/studios

Create a new studio.

**Request Body:**
```json
{
  "name": "New Studio",
  "handle": "new-studio",
  "description": "Studio description...",
  "timezone": "America/New_York",
  "tempo": "weekly",
  "synchronization_mode": "improv"
}
```

**Required:** `name`, `handle`

#### PUT /api/v1/studios/{id}

Update a studio.

**Note:** Changing `handle` requires `"force_update": true` due to potential link breakage.

#### DELETE /api/v1/studios/{id}

Delete a studio.

---

### Users

#### GET /api/v1/users

List users in the current tenant.

**Response:**
```json
[
  {
    "id": "user-uuid",
    "user_type": "person",
    "email": "user@example.com",
    "display_name": "User Name",
    "handle": "username",
    "image_url": "https://...",
    "created_at": "2026-01-01T00:00:00Z",
    "updated_at": "2026-01-05T00:00:00Z",
    "archived_at": null
  }
]
```

#### GET /api/v1/users/{id}

Get a specific user.

#### POST /api/v1/users

Create a simulated user (for testing/automation).

**Request Body:**
```json
{
  "name": "Simulated User",
  "email": "sim@example.com",
  "handle": "sim-user",
  "generate_token": true
}
```

**Response includes `token` field if `generate_token` is true.**

#### PUT /api/v1/users/{id}

Update a user. Can only update own record or simulated users you created.

**Request Body:**
```json
{
  "name": "Updated Name",
  "archived": false
}
```

#### DELETE /api/v1/users/{id}

Delete a simulated user. Only allowed if user has no associated data.

---

### API Tokens

Manage API tokens for the current user.

#### GET /api/v1/users/{user_id}/tokens

List tokens for a user.

**Response:**
```json
[
  {
    "id": "token-uuid",
    "name": "My Token",
    "user_id": "user-uuid",
    "token": "abc1*********",
    "scopes": ["read:all", "create:all"],
    "active": true,
    "expires_at": "2027-01-05T00:00:00Z",
    "last_used_at": "2026-01-05T12:00:00Z",
    "created_at": "2026-01-05T00:00:00Z",
    "updated_at": "2026-01-05T00:00:00Z"
  }
]
```

**Note:** Token value is obfuscated. Use `include=full_token` when creating to get the full token.

#### POST /api/v1/users/{user_id}/tokens

Create a new token.

**Request Body:**
```json
{
  "name": "New Token",
  "expires_at": "2027-01-05T00:00:00Z",
  "scopes": ["read:all", "create:all", "update:all"]
}
```

#### DELETE /api/v1/users/{user_id}/tokens/{id}

Delete a token.

---

## Studio-Scoped API

When accessing the API at `/studios/{studio_handle}/api/v1/`, all operations are scoped to that studio. This is required for:

- Creating/reading notes, decisions, commitments
- Accessing cycles

**Example:**
```
GET https://acme.harmonic.example/studios/engineering/api/v1/cycles/today
```

---

## Rate Limiting

Currently no rate limiting is enforced, but this may change. Design your integrations to handle 429 (Too Many Requests) responses gracefully.

---

## Webhooks

Webhook support is planned but not yet implemented. The `Tracked` concern on models has stubbed webhook delivery methods.

---

## Error Handling

Always check the HTTP status code and handle errors appropriately:

```json
// 400 Bad Request - Validation error
{ "error": "There was an error creating the decision. Please try again." }

// 401 Unauthorized - Token issues
{ "error": "Unauthorized" }
{ "error": "Token expired" }

// 403 Forbidden - Permission denied
{ "error": "API not enabled for this studio" }
{ "error": "Cannot add options" }

// 404 Not Found
{ "error": "Note not found" }
```

---

## Examples

### Create a Decision and Vote

```bash
# Create decision
curl -X POST https://acme.harmonic.example/studios/team/api/v1/decisions \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "question": "Where should we have lunch?",
    "deadline": "2026-01-05T17:00:00Z",
    "options_open": true,
    "options": [
      {"title": "Pizza Place"},
      {"title": "Sushi Restaurant"},
      {"title": "Burger Joint"}
    ]
  }'

# Vote on an option
curl -X POST https://acme.harmonic.example/studios/team/api/v1/decisions/{id}/options/{option_id}/approvals \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": 1, "stars": 1}'

# Get results
curl https://acme.harmonic.example/studios/team/api/v1/decisions/{id}/results \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Create and Join a Commitment

```bash
# Create commitment
curl -X POST https://acme.harmonic.example/studios/team/api/v1/commitments \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Team lunch on Friday",
    "description": "Lets all go to lunch together",
    "deadline": "2026-01-10T12:00:00Z",
    "critical_mass": 5
  }'

# Join commitment
curl -X POST https://acme.harmonic.example/studios/team/api/v1/commitments/{id}/join \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"committed": true}'
```

### Get Today's Activity

```bash
curl "https://acme.harmonic.example/studios/team/api/v1/cycles/today?include=notes,decisions,commitments" \
  -H "Authorization: Bearer YOUR_TOKEN"
```
