# Trustee authorization notifications

Trustee authorizations (formerly "trustee grants") have lifecycle events that should reach the affected user's inbox. Today none of these fire — TODOs sit in the model and controller waiting for the notification dispatch.

## Events

| Event | Recipient | TODO location |
|-------|-----------|---|
| Authorization offered | trustee_user | `trustee_grants_controller.rb` (on create) |
| Authorization accepted | granting_user | `trustee_grant.rb#accept!` |
| Authorization declined | granting_user | `trustee_grant.rb#decline!` |
| Authorization revoked | trustee_user | `trustee_grant.rb#revoke!` |

Use the existing `Notification` model. Add new event types to the whitelist in `notification.rb`.

## Out of scope

- **Session-occurred notifications** (start / end). Folded into [`representation-routes-refactor.md`](representation-routes-refactor.md), since the show page they link to is part of that plan.

## Related

- Source TODO comments live alongside each event handler in `trustee_grant.rb` and `trustee_grants_controller.rb` — keep those as the loadbearing reference rather than line numbers in this doc.
