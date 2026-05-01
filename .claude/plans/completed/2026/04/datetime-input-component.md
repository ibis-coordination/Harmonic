# Reusable Datetime Input Component

## Context

Datetime inputs are used in three forms: decisions (deadline), commitments (deadline), and reminder notes (scheduled_for). Each currently handles timezone and defaults differently:

- **Decisions/Commitments**: Use `_pulse_deadline_input_fields.html.erb`, display collective timezone as static text, default 1 week out, server parses with `@current_collective.timezone`
- **Reminder notes**: Use a manual `time_zone_select` dropdown defaulting to tenant timezone, no default time, no future validation

This inconsistency causes bugs (user's browser timezone doesn't match collective/tenant timezone → time parsed as past). We want a unified `DatetimeInputComponent` with browser timezone autodetection, configurable defaults, and client-side future validation.

## Implementation

### 1. IANA-to-Rails Timezone Mapping

**New file**: `app/javascript/utils/timezone_mapping.ts`

The browser returns IANA timezone names (`America/New_York`) but `time_zone_select` uses Rails names (`Eastern Time (US & Canada)`). Create a reverse mapping of `ActiveSupport::TimeZone::MAPPING`. Function: `ianaToRailsTimezone(iana: string): string | null`.

**Test**: `app/javascript/utils/timezone_mapping.test.ts`

### 2. Stimulus Controller: `datetime-input`

**New file**: `app/javascript/controllers/datetime_input_controller.ts`

Targets: `datetimeInput`, `timezoneSelect`, `error`
Values: `defaultOffset` (string, e.g. `"7d"`), `requireFuture` (boolean, default `true`)

Behavior:
- **`connect()`**: Detect browser timezone via `Intl.DateTimeFormat().resolvedOptions().timeZone`, map to Rails name, set as `timezoneSelect` value. If `datetimeInput` has no value and `defaultOffset` is set, prefill with now + offset. Set `min` attribute to current time.
- **`validate()`** (on datetime input `change`): If `requireFuture` and time is in the past, show error in `errorTarget`. Clear error otherwise.
- **`timezoneChanged()`** (on timezone select `change`): Re-run validation.

Register in `app/javascript/controllers/index.ts`.

**Test**: `app/javascript/controllers/datetime_input_controller.test.ts`

### 3. ViewComponent: `DatetimeInputComponent`

**New files**:
- `app/components/datetime_input_component.rb`
- `app/components/datetime_input_component.html.erb`

```ruby
class DatetimeInputComponent < ViewComponent::Base
  def initialize(
    field_name:,                    # e.g. "deadline" or "scheduled_for"
    timezone_field_name: "timezone",
    default_value: nil,             # pre-computed datetime string (YYYY-MM-DDTHH:MM)
    default_offset: "7d",           # JS-side default: now + offset
    require_future: true,           # client-side future validation
    default_timezone: nil           # server-side fallback for dropdown
  )
  end
end
```

The template renders a `div[data-controller="datetime-input"]` containing:
- `datetime-local` input with `data-datetime-input-target="datetimeInput"`
- `time_zone_select` dropdown with `data-datetime-input-target="timezoneSelect"`
- Error span with `data-datetime-input-target="error"`

**Test**: `test/components/datetime_input_component_test.rb` — renders correct attributes, targets, and values.

### 4. Update Deadline Partial

**Modify**: `app/views/shared/_pulse_deadline_input_fields.html.erb`

Replace the inline `datetime_local_field` + `pulse-timezone-hint` span (lines 26-28) with:
```erb
<%= render DatetimeInputComponent.new(
  field_name: "deadline",
  default_value: deadline_val.strftime('%Y-%m-%dT%H:%M'),
  default_offset: "7d",
  require_future: true,
  default_timezone: @current_collective.timezone.name,
) %>
```

The radio button structure and `deadline-options` controller remain unchanged.

### 5. Update Reminder Form

**Modify**: `app/views/notes/new.html.erb`

Replace the manual `datetime-local` + `time_zone_select` in the reminder fields section with:
```erb
<%= render DatetimeInputComponent.new(
  field_name: "scheduled_for",
  default_offset: "1d",
  require_future: true,
) %>
```

### 6. Server-Side: Unify Timezone Parsing

**Modify**: `app/controllers/application_controller.rb`

Include `ParsesScheduledTime` and update `deadline_from_params` to use `parse_scheduled_time(params[:deadline], timezone: params[:timezone])` instead of `@current_collective.timezone.parse(...)`. The concern already falls back to `@current_tenant.timezone` then UTC when no timezone param is provided.

Remove `include ParsesScheduledTime` from `NotesController` and `NotificationsController` (inherited from `ApplicationController`).

### 7. CSS

**Modify**: `app/assets/stylesheets/pulse/_components.css`

Add `.pulse-datetime-error` style for the validation error message.

## Files Changed

| File | Action |
|------|--------|
| `app/javascript/utils/timezone_mapping.ts` | Create |
| `app/javascript/utils/timezone_mapping.test.ts` | Create |
| `app/javascript/controllers/datetime_input_controller.ts` | Create |
| `app/javascript/controllers/datetime_input_controller.test.ts` | Create |
| `app/javascript/controllers/index.ts` | Modify (register new controller) |
| `app/components/datetime_input_component.rb` | Create |
| `app/components/datetime_input_component.html.erb` | Create |
| `test/components/datetime_input_component_test.rb` | Create |
| `app/views/shared/_pulse_deadline_input_fields.html.erb` | Modify (use component) |
| `app/views/notes/new.html.erb` | Modify (use component) |
| `app/controllers/application_controller.rb` | Modify (include concern, update `deadline_from_params`) |
| `app/controllers/notes_controller.rb` | Modify (remove `include ParsesScheduledTime`) |
| `app/controllers/notifications_controller.rb` | Modify (remove `include ParsesScheduledTime`) |
| `app/assets/stylesheets/pulse/_components.css` | Modify (add error style) |

## Verification

```bash
# TypeScript
docker compose exec js npm test -- --run
docker compose exec js npm run typecheck

# Ruby
docker compose exec web bundle exec rails test test/components/datetime_input_component_test.rb test/controllers/decisions_controller_test.rb test/controllers/commitments_controller_test.rb test/controllers/notes_controller_test.rb
docker compose exec web bundle exec srb tc
```

Manual: Open each form (decision, commitment, reminder note), verify timezone dropdown defaults to browser timezone, datetime prefills, past time shows error.
