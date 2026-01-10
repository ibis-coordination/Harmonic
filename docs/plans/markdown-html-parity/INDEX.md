# Markdown UI vs HTML UI Parity Analysis

## Goal

Achieve **functional parity** between both interfaces so that anything a user can DO in the HTML UI is also possible via the Markdown API.

**Focus:** Actions and capabilities, not display equivalence. Markdown pages may show less info than HTML pages - that's acceptable as long as core functionality is present.

---

## Action Linking Pattern (Required)

Every markdown page with actions MUST follow this pattern:

1. **Actions index page** at `<page_path>/actions`
2. **Individual action pages** at `<page_path>/actions/<action_name>`
3. **Section header links to actions index**: `## [Actions](<page_path>/actions)`
4. **Each action links to its page**: `* [\`action_name(params)\`](<page_path>/actions/action_name)`

### Example
```erb
## [Actions](<%= @note.path %>/actions)

* [`confirm_read()`](<%= @note.path %>/actions/confirm_read) - Confirm you have read this note
* [`add_comment(text)`](<%= @note.path %>/actions/add_comment) - Add a comment
```

### Shared Partials
- `shared/actions_index.md.erb` - Renders the actions index page
- `shared/_actions_list.md.erb` - Renders a list of actions with links

This pattern enables MCP clients to discover and navigate to action documentation.

### Existing Pages Status

Most existing pages follow this pattern correctly. When adding new actions:
- Ensure the Actions section header links to the actions index
- Ensure each action links to its individual action page
- Pages like `cycles/show.md.erb` have no actions section (acceptable - no actions needed there)

---

## Documents

| Document | Description |
|----------|-------------|
| [Core Pages](core-pages.md) | Home, Studio, Note, Decision, Commitment, Cycle pages |
| [Settings & Users](settings-and-users.md) | Studio Settings, User Profile, User Settings, Create forms |
| [Admin Panel](admin.md) | All admin functionality (entirely missing from markdown UI) |
| [File Uploads](file-uploads.md) | File attachment functionality (final step, implement separately) |

---

## Missing Actions

Actions available in HTML but not in Markdown API:

| Action | Page | Priority |
|--------|------|----------|
| ~~`pin_item()`~~ | ~~Note/Decision/Commitment Settings~~ | ✅ Done |
| ~~`unpin_item()`~~ | ~~Note/Decision/Commitment Settings~~ | ✅ Done |
| `update_profile(name, handle)` | User Settings | High |
| `create_api_token()` | User Settings | High |
| `create_subagent()` | User Settings | High |
| `add_subagent_to_studio()` | Studio Settings | High |
| `remove_subagent_from_studio()` | Studio Settings | High |
| `update_tenant_settings()` | Admin Settings | High |
| `create_tenant()` | Admin (primary only) | High |
| `invite_member()` | Studio | Medium |
| `archive_member()` | Studio Settings | Medium |
| `duplicate_decision()` | Decision | Medium |
| `impersonate_subagent()` | User Settings | Medium |
| `retry_sidekiq_job()` | Admin Sidekiq | High |
| `delete_sidekiq_job()` | Admin Sidekiq | High |

---

## Incomplete Actions

Actions that exist but are missing parameters:

| Action | Missing Params | Page | Priority |
|--------|----------------|------|----------|
| ~~`update_studio_settings()`~~ | ~~invitations, representation, file_uploads, api_enabled~~ | ~~Studio Settings~~ | ✅ Done |

Note: `deadline` on notes is a system-only attribute, not user-settable. `create_note()` only requires `text`.

---

## Missing Pages (Required for Actions)

Pages needed to perform actions that don't exist in markdown:

| Page | HTML Path | Action Enabled | Priority |
|------|-----------|----------------|----------|
| New API token | `/u/:handle/settings/tokens/new` | `create_api_token()` | High |
| New subagent | `/u/:handle/settings/subagents/new` | `create_subagent()` | High |
| Admin home | `/admin` | View admin dashboard | High |
| Admin settings | `/admin/settings` | `update_tenant_settings()` | High |
| New tenant | `/admin/tenants/new` | `create_tenant()` | High (primary only) |
| Invite member | `/studios/:handle/invite` | `invite_member()` | Medium |
| New scene | `/scenes/new` | `create_scene()` | Medium |
| Tenants list | `/admin/tenants` | Navigate to tenants | Medium (primary only) |
| Show tenant | `/admin/tenants/:subdomain` | View tenant details | High |
| Sidekiq dashboard | `/admin/sidekiq` | View/retry jobs | High (primary only) |
| Sidekiq queue | `/admin/sidekiq/queues/:name` | View queue details | High (primary only) |
| Sidekiq job | `/admin/sidekiq/jobs/:jid` | View/retry/delete job | High (primary only) |

---

## Recommendations

### Phase 1: Core Actions ✅ DONE
1. ✅ Add `pin_item()` / `unpin_item()` actions to Note, Decision, Commitment **settings** pages
2. ✅ Add missing `update_studio_settings()` params: invitations, representation, file_uploads, api_enabled

### Phase 2: User Management Actions
3. Add `update_profile(name, handle)` action to User Settings
4. Add `create_api_token()` action and new token page
5. Add `create_subagent()` action and new subagent page
6. Add `add_subagent_to_studio()` / `remove_subagent_from_studio()` to Studio Settings
7. Add `invite_member()` action to Studio page

### Phase 3: Admin Panel
8. Add `/admin` markdown view with dashboard info
9. Add `/admin/settings` with `update_tenant_settings()` action
10. Add tenant management pages (primary subdomain only)
11. Add Sidekiq dashboard with full job visibility and retry/delete actions

**Note:** Admin templates should show actions conditionally to prepare for future `readonly_admin` permission type. See [admin.md](admin.md) for details.

### Phase 4: File Uploads (Final Step)
12. Implement file attachment functionality - see [file-uploads.md](file-uploads.md)

### Phase 5: Refactor Action Descriptions
13. Consolidate all action and parameter descriptions into `ActionsHelper` as the single source of truth
14. Update controllers to use `ActionsHelper` for `describe_*` methods instead of duplicating param definitions
15. This reduces duplication between `ActionsHelper` and individual controller `describe_*` methods

---

## Future Considerations (Display/Navigation)

These are display-only differences that don't block functionality. Address after functional parity is achieved:

- Heartbeat indicators on home/studio pages
- Scenes section on home page (navigation convenience)
- Profile images and created-by info
- Breadcrumb navigation
- Read/unread counts, open/closed counts
- Countdown timers
- Other subdomains/tenant switching
