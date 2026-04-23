# User Safety & Content Moderation

This document covers the user safety features and content moderation tools available in Harmonic.

## Overview

The safety system is built around a layered approach:

1. **Self-protection** — Users can block other users for immediate relief, without waiting for admin intervention.
2. **Escalation** — Users can report harmful content, which lands in an admin review queue.
3. **Admin action** — Admins can review reports, delete content, suspend users, or reset compromised accounts.

Content stays visible while a report is under review. This prevents reports from being weaponized as a censorship tool. The reporter can block the author in the meantime for personal protection.

## User-facing features

### Blocking

Users can block other users from the user profile page. Blocks are tenant-wide (apply across all collectives). When you block someone:

- Their content is hidden from you
- They cannot interact with your content
- Neither party is notified of the block

Users manage their blocks from their settings page. Admins can see block counts on user detail pages.

### Reporting

Users can report notes, decisions, and commitments via the "Report" button on content pages. The report form allows selecting a reason (harassment, spam, inappropriate, misinformation, other) and adding a description. An "Also block" checkbox lets users block the author and file the report in one step.

A snapshot of the content is captured at report time, preserving evidence even if the content is later edited or deleted.

## Admin moderation

App admins access the moderation queue at `/app-admin/reports`. The report detail page shows:

- The reported content and a snapshot from the time of report
- Reporter information and their description
- How many total reports exist against the content author
- A review form for updating the report status and adding admin notes

From the report detail page, admins can:

- **Review the report** — mark as dismissed, reviewed, or actioned
- **Delete the content** — soft-deletes the content (text is scrubbed, tombstone shown)
- **Navigate to the user** — suspend, or trigger an account security reset

### Account security reset

A combined admin action that force-resets a user's password, revokes all active sessions, and deletes all API tokens. Used when an account may be compromised.

## Access control

Moderation is handled exclusively by **app admins** through the `AppAdminController`. Tenant admins and collective admins do not have access to the moderation queue. This boundary is enforced by route-enumerating access control tests that automatically cover any new routes added to admin controllers.

## Future work

- **Collective-level moderation** — collective admins moderating reports for their own collective's content
- **Reporter notifications** — notify reporters when their report is resolved
- **Report-a-user** — report a pattern of behavior, not just individual content
