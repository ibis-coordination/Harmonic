# Plan: Content Reporting — Design & Implementation

**Status: Implemented**

## Context

Content reporting allows users to flag harmful content for moderator review. It builds on two prerequisites:
1. **User blocking** — immediate self-protection
2. **Content deletion** — soft delete with text scrubbing via `SoftDeletable` concern

When a user encounters harmful content, they can block the author (immediate, self-service) and report the content (escalation to admin). The admin can then soft-delete the content, suspend the user, or do an account security reset.

## Architecture

### Reporting follows the actions pattern

Reporting is implemented as a `report_content` action on each resource controller (notes, decisions, commitments), consistent with all other user-facing operations in Harmonic. There is no standalone `ContentReportsController` — all reporting goes through the resource controllers.

**Routes:**
- `GET /n/:id/report` — report form (HTML), rendered from `content_reports/new.html.erb`
- `GET /n/:id/actions/report_content` — action description (markdown/actions API)
- `POST /n/:id/actions/report_content` — submit report (HTML redirects, markdown renders action result)
- Same pattern for `/d/:id/` (decisions) and `/c/:id/` (commitments)

**Business logic** is centralized in `ApiHelper#report_content(resource)`, which:
- Creates the `ContentReport` with a `content_snapshot` (preserves reported text)
- Optionally creates a `UserBlock` when `also_block` param is set
- Validates via model (duplicate prevention, self-report prevention)

### Action visibility uses conditional_actions

The `report_content` action appears in the actions list only when:
- User is authenticated
- User is not the content author
- User has not already reported this content

This is implemented via `REPORT_CONTENT_CONDITION` lambda in `ActionsHelper`, used as a `conditional_actions` entry on all three resource show page route definitions.

### Admin moderation

Reports are managed at `/app-admin/reports` — **app admins only**. This follows the strict admin controller separation:
- `SystemAdminController` — sys_admin role only
- `AppAdminController` — app_admin role only
- `TenantAdminController` — tenant admin role only

No exceptions. Access control invariants are enforced by `AdminAccessControlTest`, which enumerates all routes for each admin controller and verifies unauthorized users are blocked.

**Admin report detail page shows:**
- Report status, reason, reporter (linked to admin user page)
- Reported content with collective name, content preview, and "View content" link
- Content snapshot from time of report (preserved even if content is later edited or deleted)
- Reporter's description
- Count of total reports against the content author
- Review form (always visible — admins can update reviews, not just create them)
- "Delete this content" button (soft-deletes via `SoftDeletable`, logged to `SecurityAuditLog`)
- Link to reported user's admin page (suspend, security reset)

**Pending report count** is shown on the app admin dashboard.

## Key Files

| File | Purpose |
|------|---------|
| `app/services/api_helper.rb` | `report_content` method — business logic |
| `app/services/actions_helper.rb` | Action definition + `REPORT_CONTENT_CONDITION` |
| `app/models/content_report.rb` | Model with validations, reasons, statuses |
| `app/controllers/notes_controller.rb` | `report`, `describe_report_content`, `report_content_action` |
| `app/controllers/decisions_controller.rb` | Same pattern |
| `app/controllers/commitments_controller.rb` | Same pattern |
| `app/controllers/app_admin_controller.rb` | Admin queue, detail, review, delete-from-report |
| `app/views/content_reports/new.html.erb` | Shared report form (rendered by each resource controller) |
| `app/views/content_reports/new.md.erb` | Markdown report form |
| `app/views/app_admin/show_report.html.erb` | Admin report detail |
| `app/views/app_admin/reports.html.erb` | Admin report queue |
| `app/helpers/markdown_helper.rb` | `build_condition_context` fix for conditional actions |
| `db/migrate/20260423034320_add_content_snapshot_to_content_reports.rb` | Added `content_snapshot` column |

## Design Decisions

### Report button location
In the `ResourceHeaderComponent` action bar on show pages, alongside Copy/Pin/Edit/Settings. Also in markdown show views as a link at the bottom.

### Not shown on comments (V1)
If a comment is problematic, report the parent content or block the user.

### Content stays visible while under review
Nothing happens to reported content while pending review. This prevents weaponizing reports to censor content. The reporter can block the author for immediate personal relief.

### Report form lives at `/n/:id/report` (not a standalone route)
The form is a sub-route of the content being reported, not a standalone `/content-reports/new?reportable_type=...` route. This is cleaner and consistent with the resource-scoped routing pattern.

### Content snapshot preserved at report time
`content_snapshot` captures the content text when the report is filed, using the same `content_snapshot` method from `SoftDeletable`. This preserves evidence even if content is edited or deleted before review.

### "Also block" checkbox on report form
Single form submission creates both report and block. Respects that most reporters want both: escalation (report) and immediate protection (block).

### Admin controller boundaries are inviolable
App admin routes are only accessible to app admins. No `except:` clauses on `ensure_app_admin`. Tenant admin report access, if needed in the future, belongs in `TenantAdminController`, not as an exception in `AppAdminController`.

## Future Work

- **Collective-level moderation** — collective admins moderating reports for their collective's content (separate feature, not an exception in app admin)
- **Reporter notification** — notify the reporter when their report is resolved
- **Report-a-user** — report a user's pattern of behavior, not just individual content
