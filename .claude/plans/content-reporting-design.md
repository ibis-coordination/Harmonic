# Plan: Content Reporting — Design & Implementation

## Context

The `ContentReport` model, controller, admin review queue, and routes are already in place (backend skeleton). This plan covers the **UX integration, reporter experience, and moderation workflow** needed to make reporting a real feature.

**Prerequisites (must be implemented first):**
1. **User blocking** — users can block other users for immediate self-protection
2. **Content deletion** — soft delete with text scrubbing, so admins have a tool to remove content

Reporting builds on both: when a user encounters harmful content, they can block the author (immediate, self-service) and report the content (escalation to admin). The admin can then soft-delete the content, suspend the user, or do an account security reset.

## Research: Established Patterns

### Where the report button lives (every major platform)
Report is always in a **contextual menu on the content itself** — close to what's being reported. Never in global nav or settings.
- Reddit: "Report" link below each post
- Twitter/X: three-dot menu → "Report post"
- Discord: right-click message → "Report Message"

### Reporter feedback
- Every platform shows immediate confirmation ("Thanks for reporting")
- Some (Instagram, YouTube) notify the reporter when the report is resolved
- Content stays visible while under review — premature hiding enables abuse of the report system

### Category design
- 4–6 clear categories + "Other" with a text field is the sweet spot
- Too many (Reddit's 14) creates decision paralysis; too few gives moderators nothing to work with

### Procedural fairness (ACM research)
Users perceive greater fairness when:
1. Community guidelines are shown alongside the report form
2. A text box for open-ended feedback is included (gives the reporter "voice")
3. Enforcement is consistent

## Design Decisions

### 1. Where the report button lives

**On content pages** (notes, decisions, commitments): in the `ResourceHeaderComponent` action bar, alongside Copy/Pin/Edit/Settings. Shown as a link with the report octicon.

**Conditions for showing:**
- User is logged in
- Content was not created by the current user
- Content is not already deleted
- User has not already reported this content (prevent duplicate noise)

**Not shown on comments (V1).** If a comment is problematic, report the parent content or block the user. Comments are lightweight — adding report to every comment adds visual noise.

### 2. The report form

**Location:** `/content-reports/new` (already implemented). Navigating away from the content is intentional — it's a deliberate, considered action.

**Content snapshot:** When the report is created, a snapshot of the reported content's text is stored on the `ContentReport` record in a `content_snapshot` text field. This preserves what the reporter saw at report time — the content may be edited or deleted before an admin reviews it. This requires a migration to add the column and a controller change to populate it at creation time.

**Form fields:**
- **Content preview** — show a truncated preview of the reported content at the top so the reporter confirms they're reporting the right thing
- **Reason** (required select, 5 options — already implemented):
  - Harassment
  - Spam
  - Inappropriate
  - Misinformation
  - Other
- **Description** (optional textarea — already implemented): free-text context for moderators
- **"Also block this user" checkbox** (default unchecked): creates a UserBlock alongside the report, so the reporter gets immediate protection without a separate action

### 3. Feedback to the reporter

**Immediately:** Flash — "Thank you for your report. Our moderators will review it."

If the "Also block" checkbox was checked: "Thank you for your report. @handle has been blocked and our moderators will review the reported content."

**After review (V2):** Notification to the reporter when resolved. Not in V1.

### 4. What happens to reported content

**Nothing — while pending review.** Content stays visible. This prevents weaponizing reports to censor content. The reporter can block the author for immediate personal relief.

**After admin review**, the admin can:
- **Dismiss** — false alarm
- **Reviewed** — acknowledged, no action needed
- **Actioned** — admin took action. From the report detail page, the admin can:
  - Navigate to the content and **soft-delete** it (uses content deletion feature)
  - Navigate to the user and **suspend**, **account security reset**, or just note the incident
  - Both, for serious cases

### 5. Admin moderation workflow

**Already implemented:**
- `/app-admin/reports` — queue with status filtering
- `/app-admin/reports/:id` — detail view with content preview, reporter info, review form
- Review action with status + admin notes
- Security audit logging

**Add in this phase:**
- Pending report count on the app admin dashboard
- Direct "Delete this content" button on the report detail page (calls soft-delete, saves a navigation step)
- Direct "Block reporter's account" shortcut? No — admin actions (suspend, security reset) are more appropriate than user-level blocks.

### 6. Combined "report and block"

The report form includes an "Also block this user" checkbox. When checked, the controller:
1. Creates the `ContentReport` (existing logic)
2. Creates a `UserBlock` for the reporter → content author (if not already blocked)
3. Returns a combined flash message

This is a single form submission, not two separate actions. It respects that most reporters want both: escalation (report) and immediate protection (block).

### 7. Tenant admin access (self-hosted instances)

Currently only app admins can see the report queue. For self-hosted instances, there are no app admins. This plan adds:
- Tenant admins can access `/app-admin/reports` (scoped to their tenant's reports)
- Requires extending the `ensure_app_admin` check to also allow tenant admins for report-related actions

This is a narrow scope change — tenant admins only get report access, not full app admin powers.

## Implementation

### Phase 1: Report button on content pages

Add "Report" link to:
- `app/views/notes/show.html.erb` — in `header.with_actions` block
- `app/views/decisions/show.html.erb` — same
- `app/views/commitments/show.html.erb` — same

Conditions: logged in, not own content, not deleted, not already reported.

For the "already reported" check: query `ContentReport.where(reporter: current_user, reportable: resource).exists?`. Cache this in the controller to avoid N+1 on feed pages (only needed on show pages, not feeds).

### Phase 2: Improve report form

**Content preview:** At the top of the form, show the type, author, and truncated text of the content being reported. Requires passing the reportable to the view (controller already loads it via `find_reportable`).

**"Also block this user" checkbox:** Add to the form. Controller handles both actions in a single request.

### Phase 3: Content snapshot on report creation

**Migration:** Add `content_snapshot` (text, nullable) to `content_reports` table.

**Controller:** In `ContentReportsController#create`, after loading the reportable, capture its text via `content_snapshot` (same method used by the deletion audit trail) and store it on the report:

```ruby
report = ContentReport.new(
  reporter: current_user,
  reportable: reportable,
  reason: params[:reason],
  description: params[:description],
  content_snapshot: reportable.content_snapshot.to_json,
)
```

**Admin view:** On `show_report.html.erb`, show the snapshot alongside the live content (or in place of it if the content has been deleted). Label clearly: "Content at time of report."

### Phase 4: Combined report + block

Update `ContentReportsController#create`:
- After creating the report, check `params[:also_block]`
- If checked and no existing block, create `UserBlock.create(blocker: current_user, blocked: reportable.created_by)`
- Adjust flash message to mention both actions

### Phase 5: Admin dashboard + delete from report

**Pending count:** Add pending report count to the app admin dashboard page.

**Delete from report detail:** Add a "Delete this content" button on `show_report.html.erb` that calls the soft-delete action on the reportable. Only shown when the content is not already deleted.

### Phase 6: Tenant admin access to reports

Extend report access to tenant admins:
- In `app_admin_controller.rb`, allow tenant admin access to `reports`, `show_report`, and `execute_review_report` actions
- Scope the report query to the current tenant for tenant admins (app admins see all)

### Phase 7: Tests

**Report button:**
- Shows on other users' content
- Hidden on own content
- Hidden on deleted content
- Hidden if already reported

**Combined report + block:**
- Report with "also block" creates both records
- Report without checkbox creates only report
- Flash message reflects which actions were taken
- Block not duplicated if already blocked

**Admin workflow:**
- Report → admin reviews → marks as actioned
- Report → admin deletes content from report detail page
- Tenant admin can access reports for their tenant
- Tenant admin cannot access other tenants' reports

## Open Questions

1. **Should there be a way to report a user (not content)?** V1 says no — report content, block users. If a user's pattern of behavior is the issue, the admin can see who has the most reports against them. Formal "report user" is a V2 consideration.

2. **Rate limiting on reports?** One report per user per content item is already enforced by uniqueness constraint. Rack::Attack handles general POST rate limiting. Probably sufficient for V1.

3. **AI agent content?** Reports on AI-generated content work the same way. Admin can delete the content and/or suspend the agent.

## References

- [Flagging & Reporting UI Pattern](https://ui-patterns.com/patterns/flagging-and-reporting)
- [Personalizing Content Moderation (ACM)](https://dl.acm.org/doi/10.1145/3610080)
- [Procedural Fairness in Flag Submissions (ACM)](https://dl.acm.org/doi/10.1145/3797820)
- [Content Moderation Trends 2026](https://getstream.io/blog/content-moderation-trends/)
