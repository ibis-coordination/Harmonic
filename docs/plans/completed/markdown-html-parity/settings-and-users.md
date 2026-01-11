# Settings & Users - Functional Gaps

This document covers missing **actions and capabilities** on settings, user, and create pages.

[← Back to Index](INDEX.md)

---

## Studio Settings (`/studios/:handle/settings`)

### Missing Actions

| Action | HTML Capability | Markdown Status |
|--------|-----------------|-----------------|
| `add_subagent_to_studio()` | Add subagent dropdown | Missing |
| `remove_subagent_from_studio()` | Remove subagent button | Missing |
| `archive_member()` | Archive member button | Missing |

### Incomplete Actions

| Action | Missing Params | Notes |
|--------|----------------|-------|
| `update_studio_settings()` | invitations | Who can invite members |
| `update_studio_settings()` | representation | Who can represent studio |
| `update_studio_settings()` | file_uploads | Enable/disable, size limits |
| `update_studio_settings()` | api_enabled | Enable/disable API access |

### Notes
- Basic settings (name, handle, visibility, cycle) work
- Image upload is display-only concern

---

## User Profile (`/u/:handle`)

### Missing Actions

None identified. User profile is primarily for viewing.

### Notes
- Profile image is display-only
- Subagent badge is display-only
- All navigation to settings works

---

## User Settings (`/u/:handle/settings`)

### Missing Actions

| Action | HTML Capability | Markdown Status |
|--------|-----------------|-----------------|
| `update_profile(name, handle)` | Edit name/handle form fields | Missing |
| `create_api_token()` | "Create Token" button | Missing |
| `create_subagent()` | "Create Subagent" button | Missing |
| `impersonate_subagent()` | "Impersonate" button | Missing |
| `delete_subagent()` | Delete subagent | Missing (if exists in HTML) |

### Missing Pages

| Page | Purpose |
|------|---------|
| `/u/:handle/settings/tokens/new` | Create new API token |
| `/u/:handle/settings/subagents/new` | Create new subagent |

### Notes
- User settings page shows info but lacks all modification actions
- This is a significant functional gap for API/subagent management

---

## New Note Page (`/studios/:handle/note`)

### Incomplete Actions

| Action | Missing Params | Notes |
|--------|----------------|-------|
| `create_note()` | title | Optional title field |
| `create_note()` | pin | Pin to studio on create |

### Notes
- Basic note creation works (text content)
- Deadline is a system-only attribute, not user-settable
- File uploads covered separately in [file-uploads.md](file-uploads.md)

---

## New Decision Page (`/studios/:handle/decide`)

### Incomplete Actions

None - decision creation works fully (question, options, deadline, threshold).

### Notes
- File uploads covered separately in [file-uploads.md](file-uploads.md)

---

## New Commitment Page (`/studios/:handle/commit`)

### Incomplete Actions

None - commitment creation works fully (title, description, deadline, critical mass).

### Notes
- File uploads covered separately in [file-uploads.md](file-uploads.md)

---

## Summary: Settings & User Actions Needed

### High Priority

| Action | Page | Notes |
|--------|------|-------|
| `update_profile(name, handle)` | User Settings | Core user management |
| `create_api_token()` | User Settings | Required for API access |
| `create_subagent()` | User Settings | Subagent management |
| `add_subagent_to_studio()` | Studio Settings | Subagent access control |
| `remove_subagent_from_studio()` | Studio Settings | Subagent access control |
| `update_studio_settings()` params | Studio Settings | invitations, representation, file_uploads, api_enabled |
| `create_note()` params | New Note | title, pin |

### Medium Priority

| Action | Page | Notes |
|--------|------|-------|
| `archive_member()` | Studio Settings | Member management |
| `impersonate_subagent()` | User Settings | Debugging/testing |

### Separate Implementation

See [file-uploads.md](file-uploads.md) for file attachment functionality.
