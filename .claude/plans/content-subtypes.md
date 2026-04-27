# Content Subtypes — Overview

The app has three content types — Note, Decision, Commitment — each as a separate model/table. We're adding subtypes to support different workflows within each type.

## Subtypes

| Parent | Subtype | Behavior |
|--------|---------|----------|
| Note | `text` (default) | Current behavior, unchanged |
| Note | `reminder` | Text + resurfaces in feed on a schedule (one-time or recurring) |
| Note | `table` | Structured tabular data with named columns and typed rows |
| Decision | `vote` (default) | Current behavior, unchanged |
| Decision | `lottery` | Random selection from options instead of voting |
| Decision | `log` | Record of a decision already made — no voting UI |
| Commitment | `action` (default) | Current behavior, unchanged |
| Commitment | `calendar_event` | Date/time/location + RSVP instead of "Join" |
| Commitment | `policy` | Ongoing rule — no deadline, "Sign" instead of "Join" |

## Approach: String `subtype` Column (Not STI)

Subtypes share 90%+ behavior with their parent. A simple string column with validation and predicate methods is lighter than STI (which would create 9 new model classes, complicate Sorbet typing, and add class-loading overhead). This matches the existing pattern — `Note` already uses conditional behavior for `is_comment?` vs standalone.

## Individual Plans

Implementation order (simplest to most complex):

1. [Foundation](content-subtypes-foundation.md) — add `subtype` column + model infrastructure
2. [Decision Log](content-subtypes-decision-log.md) — no voting, just a record
3. [Commitment Policy](content-subtypes-commitment-policy.md) — ongoing rules, no deadline
4. [Calendar Event](content-subtypes-calendar-event.md) — date/time/location + RSVP
5. [Lottery Decision](content-subtypes-lottery.md) — random draw from options
6. [Reminder Note](content-subtypes-reminder.md) — resurface on schedule
7. [Table Note](content-subtypes-data.md) — structured tabular data with row-level operations
