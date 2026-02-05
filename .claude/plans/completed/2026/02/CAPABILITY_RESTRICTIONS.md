# Plan: Capability Restrictions for Subagents

## Goal

Allow subagent owners to restrict which actions their agents can take. This provides safety controls so users can grant limited permissions to AI agents.

## Current State

- Subagents can execute any action the user type allows (via `ActionAuthorization`)
- No per-agent filtering of capabilities
- `users.agent_configuration` jsonb column exists but only stores `identity_prompt`

## Design

### Capability Model

**Allowlist approach**:
- If `capabilities` key is absent (null), all grantable actions are allowed (unconfigured default)
- If `capabilities` is an empty array, NO grantable actions are allowed (fully restricted)
- If `capabilities` has items, only those listed actions are permitted

```json
{
  "identity_prompt": "You are a helpful assistant...",
  "capabilities": ["create_note", "add_comment", "vote", "add_options"]
}
```

### Where to Enforce

**Two enforcement points:**

1. **Action Listing** - Filter available actions shown to agents (in YAML frontmatter)
2. **Action Execution** - Block unauthorized actions at execution time

Both should use the same capability check logic.

### Action Categories

**Always Allowed (Infrastructure)** - Essential for navigation/operation:
- `send_heartbeat` - Required to access studios
- `mark_read`, `dismiss`, `mark_all_read` - Notification management
- `search` - Content discovery

**Grantable (Configurable)** - Owner can allow/deny:
- `create_note`, `update_note`, `pin_note`, `unpin_note`, `confirm_read`
- `add_comment`
- `create_decision`, `update_decision_settings`, `pin_decision`, `unpin_decision`
- `vote`, `add_options`
- `create_commitment`, `update_commitment_settings`, `join_commitment`, `pin_commitment`, `unpin_commitment`
- `add_attachment`, `remove_attachment`
- `create_reminder`, `delete_reminder` - Reminder management

**Always Blocked** - Subagents can never perform:
- `create_studio`, `join_studio`, `update_studio_settings` - Studio management
- `create_subagent`, `add_subagent_to_studio`, `remove_subagent_from_studio` - Subagent management
- `create_api_token` - Token management
- `update_profile` - Profile changes
- `create_webhook`, `update_webhook`, `delete_webhook`, `test_webhook` - Webhook management
- `suspend_user`, `unsuspend_user` - User suspension
- `update_tenant_settings`, `create_tenant` - Tenant admin
- `retry_sidekiq_job` - System admin

---

## Implementation

### Step 1: Add Capability Check Module

Create `app/services/capability_check.rb`:

```ruby
# typed: true

module CapabilityCheck
  extend T::Sig

  # Actions that subagents can always perform (infrastructure)
  SUBAGENT_ALWAYS_ALLOWED = %w[
    send_heartbeat
    mark_read dismiss mark_all_read
    search
  ].freeze

  # Actions that subagents can never perform
  SUBAGENT_ALWAYS_BLOCKED = %w[
    create_studio join_studio update_studio_settings
    create_subagent add_subagent_to_studio remove_subagent_from_studio
    create_api_token update_profile
    create_webhook update_webhook delete_webhook test_webhook
    suspend_user unsuspend_user
    update_tenant_settings create_tenant
    retry_sidekiq_job
  ].freeze

  # Actions that can be granted/denied via configuration
  SUBAGENT_GRANTABLE_ACTIONS = %w[
    create_note update_note pin_note unpin_note confirm_read
    add_comment
    create_decision update_decision_settings pin_decision unpin_decision
    vote add_options
    create_commitment update_commitment_settings join_commitment pin_commitment unpin_commitment
    add_attachment remove_attachment
    create_reminder delete_reminder
  ].freeze

  # Check if a user has capability for an action
  #
  # @param user [User] The user attempting the action
  # @param action_name [String] The action to check
  # @return [Boolean] true if allowed, false if denied
  sig { params(user: User, action_name: String).returns(T::Boolean) }
  def self.allowed?(user, action_name)
    # Non-subagents have no capability restrictions
    return true unless user.subagent?

    # Infrastructure actions are always allowed
    return true if SUBAGENT_ALWAYS_ALLOWED.include?(action_name)

    # Blocked actions are never allowed
    return false if SUBAGENT_ALWAYS_BLOCKED.include?(action_name)

    # Check configured capabilities for grantable actions
    capabilities = user.agent_configuration&.dig("capabilities")

    # No capabilities configured = all grantable actions allowed
    return true if capabilities.blank?

    # Check if action is in the allowed list
    capabilities.include?(action_name)
  end

  # Get the list of allowed actions for a user
  #
  # @param user [User] The user to check
  # @return [Array<String>] List of allowed action names
  sig { params(user: User).returns(T::Array[String]) }
  def self.allowed_actions(user)
    return ActionsHelper::ACTION_DEFINITIONS.keys unless user.subagent?

    capabilities = user.agent_configuration&.dig("capabilities")

    grantable = if capabilities.blank?
                  SUBAGENT_GRANTABLE_ACTIONS
                else
                  capabilities & SUBAGENT_GRANTABLE_ACTIONS
                end

    SUBAGENT_ALWAYS_ALLOWED + grantable
  end

  # Get the list of restricted actions for a user (for display)
  #
  # @param user [User] The user to check
  # @return [Array<String>, nil] List of restricted actions, or nil if no restrictions
  sig { params(user: User).returns(T.nilable(T::Array[String])) }
  def self.restricted_actions(user)
    return nil unless user.subagent?

    capabilities = user.agent_configuration&.dig("capabilities")
    return nil if capabilities.blank?

    SUBAGENT_GRANTABLE_ACTIONS - capabilities
  end
end
```

### Step 2: Integrate into ActionAuthorization

Update `app/services/action_authorization.rb`:

```ruby
def self.authorized?(action_name, user, context = {})
  action = ActionsHelper::ACTION_DEFINITIONS[action_name]
  return false unless action

  auth = action[:authorization]
  return false if auth.nil?

  # Check base authorization first
  return false unless check_authorization(auth, user, context)

  # Then check capability restrictions for subagents
  return false unless CapabilityCheck.allowed?(user, action_name)

  true
end
```

### Step 3: Filter Actions in Markdown Layout

Update `app/helpers/markdown_helper.rb` in `available_actions_for_current_route`:

```ruby
def available_actions_for_current_route
  route_pattern = "#{controller_path}##{action_name}"
  actions = ActionsHelper.actions_for_route(route_pattern)

  # Filter by capability for subagents
  if @current_user&.subagent?
    actions = actions.select { |a| CapabilityCheck.allowed?(@current_user, a[:name]) }
  end

  actions
end
```

### Step 4: Add Execution-Time Check

Create `app/controllers/concerns/action_capability_check.rb`:

```ruby
# typed: false

module ActionCapabilityCheck
  extend ActiveSupport::Concern

  included do
    before_action :check_capability_for_action
  end

  private

  def check_capability_for_action
    # Only check on action execution requests
    return unless request.path.include?('/actions/') && request.post?

    action_name = extract_action_name_from_path
    return if action_name.blank?
    return if current_user.blank?

    unless CapabilityCheck.allowed?(current_user, action_name)
      render_capability_denied(action_name)
    end
  end

  def extract_action_name_from_path
    match = request.path.match(%r{/actions/([^/]+)})
    match[1] if match
  end

  def render_capability_denied(action_name)
    error_message = "Your capabilities do not include '#{action_name}'"

    respond_to do |format|
      format.md { render plain: "Error: #{error_message}", status: :forbidden }
      format.html { render plain: "Forbidden: #{error_message}", status: :forbidden }
      format.json { render json: { error: error_message }, status: :forbidden }
    end
  end
end
```

Include in `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  include ActionCapabilityCheck
  # ...
end
```

### Step 5: Show Capabilities on /whoami

Update `app/views/whoami/index.md.erb` (add after identity prompt section):

```erb
<% if @current_user.subagent? %>
## Your Capabilities

<% restricted = CapabilityCheck.restricted_actions(@current_user) %>
<% if restricted.present? %>
Your owner has restricted your capabilities. You **cannot** perform:
<% restricted.each do |action| %>
- `<%= action %>`
<% end %>

You can perform all other standard actions.
<% else %>
You have full capabilities (no restrictions configured by your owner).
<% end %>
<% end %>
```

### Step 6: Add UI for Configuration

Update `app/views/users/settings.html.erb` (add in subagent section):

```erb
<% if @settings_user.subagent? %>
  <div class="pulse-form-section">
    <label class="pulse-form-label">Capabilities</label>
    <p class="pulse-form-hint">
      Select which actions this agent can perform. If none are selected, all actions are allowed.
      Infrastructure actions (search, notification dismissal, heartbeat) are always allowed.
    </p>

    <% current_caps = @settings_user.agent_configuration&.dig("capabilities") || [] %>
    <div class="pulse-checkbox-group">
      <% CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS.each do |action| %>
        <% checked = current_caps.empty? || current_caps.include?(action) %>
        <label class="pulse-checkbox-label">
          <%= check_box_tag "capabilities[]", action, checked, id: "cap_#{action}" %>
          <code><%= action %></code>
          <span class="pulse-form-hint-inline"><%= ActionsHelper::ACTION_DEFINITIONS.dig(action, :description) %></span>
        </label>
      <% end %>
    </div>

    <p class="pulse-form-hint" style="margin-top: 0.5rem;">
      <strong>Tip:</strong> Uncheck all boxes to allow all actions. Check only the actions you want to permit.
    </p>
  </div>
<% end %>
```

Update `app/controllers/users_controller.rb` in `update_settings`:

```ruby
# Handle capabilities for subagents
if settings_user.subagent? && params.key?(:capabilities)
  settings_user.agent_configuration ||= {}

  capabilities = params[:capabilities]
  if capabilities.is_a?(Array) && capabilities.any?
    # Filter to only valid grantable actions
    valid_caps = capabilities & CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS
    settings_user.agent_configuration["capabilities"] = valid_caps.presence
  else
    # Empty or nil = no restrictions
    settings_user.agent_configuration.delete("capabilities")
  end

  settings_user.save!
end
```

---

## Files to Create/Modify

| File | Change |
|------|--------|
| `app/services/capability_check.rb` | **New** - Capability check logic |
| `app/services/action_authorization.rb` | Add capability check call |
| `app/helpers/markdown_helper.rb` | Filter actions by capability |
| `app/controllers/concerns/action_capability_check.rb` | **New** - Execution-time check |
| `app/controllers/application_controller.rb` | Include capability check concern |
| `app/views/whoami/index.md.erb` | Show agent capabilities |
| `app/views/users/settings.html.erb` | Capability checkboxes UI |
| `app/controllers/users_controller.rb` | Handle capability updates |
| `test/services/capability_check_test.rb` | **New** - Unit tests |
| `test/integration/subagent_capability_test.rb` | **New** - Integration tests |

---

## Testing Plan

### Unit Tests (capability_check_test.rb)

1. `test "non-subagent users have no restrictions"`
2. `test "subagent with no capabilities configured can do all grantable actions"`
3. `test "subagent with capabilities configured can only do listed actions"`
4. `test "subagent can always perform infrastructure actions"`
5. `test "subagent cannot perform blocked actions regardless of config"`
6. `test "allowed_actions returns infrastructure + configured for subagent"`
7. `test "restricted_actions returns nil when no config"`
8. `test "restricted_actions returns denied actions when configured"`

### Integration Tests (subagent_capability_test.rb)

1. `test "subagent sees only allowed actions in markdown frontmatter"`
2. `test "subagent can execute allowed action"`
3. `test "subagent cannot execute disallowed action - returns 403"`
4. `test "subagent cannot execute blocked action even if in capabilities"`
5. `test "subagent can always execute infrastructure actions"`
6. `test "capability check works through AgentNavigator flow"`
7. `test "capability UI shows current configuration"`
8. `test "capability UI updates configuration correctly"`

### Manual Test Checklist

1. Create a subagent with restricted capabilities (only `create_note`, `add_comment`)
2. Navigate to `/whoami` as the subagent - verify restricted actions shown
3. Navigate to a decision page - verify `vote` action not in frontmatter
4. Try to POST to vote action - verify 403 response
5. Execute `create_note` - verify succeeds
6. Execute `search` - verify succeeds (always allowed)
7. Update capabilities via settings UI - verify changes saved
8. Clear all checkboxes - verify "all actions allowed" state

---

## Migration Notes

- **No database migration needed** - Uses existing `agent_configuration` jsonb column
- **Backwards compatible** - Existing subagents with no capabilities configured retain full access
- **Opt-in restriction** - Users must explicitly configure capabilities to restrict agents

---

## Open Questions

1. **UI behavior**: Should unchecked = denied, or should we have explicit "restrict this agent" toggle first?
2. **Presets**: Should we add quick presets like "Read-only", "Commenter", "Full participant"?
3. **Feedback to agent**: When action is denied, should we tell the agent why in a helpful way?

---

## Future Enhancements

1. **Capability presets** - "Read-only", "Commenter", "Full participant"
2. **Per-studio capabilities** - Different capabilities in different studios
3. **Audit log** - Log denied capability attempts
4. **Capability templates** - Save and reuse capability configurations
