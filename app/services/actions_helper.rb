# typed: true

# ActionsHelper is the single source of truth for all action definitions.
# Controllers should use this helper to get action descriptions and parameters
# rather than duplicating definitions in describe_* methods.
class ActionsHelper
  extend T::Sig

  # Full action definitions with parameter details
  # Each action has: description, params_string (for display), and params (detailed param info)
  ACTION_DEFINITIONS = {
    # Studio actions
    "create_studio" => {
      description: "Create a new studio",
      params_string: "(name, handle, description, timezone, tempo, synchronization_mode, invitations, representation, file_uploads, api_enabled)",
      params: [
        { name: "name", type: "string", description: "The name of the studio" },
        { name: "handle", type: "string", description: "The handle of the studio (used in the URL)" },
        { name: "description", type: "string", description: "A description of the studio that will appear on the studio homepage" },
        { name: "timezone", type: "string", description: "The timezone of the studio" },
        { name: "tempo", type: "string", description: 'The tempo of the studio: "daily", "weekly", or "monthly"' },
        { name: "synchronization_mode", type: "string", description: 'The synchronization mode: "improv" or "orchestra"' },
        { name: "invitations", type: "string", description: 'Who can invite new members: "all_members" or "only_admins" (optional)' },
        { name: "representation", type: "string", description: 'Who can represent the studio: "any_member" or "only_representatives" (optional)' },
        { name: "file_uploads", type: "boolean", description: "Whether file attachments are allowed (optional)" },
        { name: "api_enabled", type: "boolean", description: "Whether API access is allowed (optional)" },
      ],
    },
    "join_studio" => {
      description: "Join the studio",
      params_string: "()",
      params: [
        { name: "code", type: "string", required: false, description: "Invite code (optional for scenes)" },
      ],
    },
    "update_studio_settings" => {
      description: "Update studio settings",
      params_string: "(name, description, timezone, tempo, synchronization_mode, invitations, representation, file_uploads, api_enabled)",
      params: [
        { name: "name", type: "string", description: "The name of the studio" },
        { name: "description", type: "string", description: "A description of the studio" },
        { name: "timezone", type: "string", description: "The timezone of the studio" },
        { name: "tempo", type: "string", description: 'The tempo of the studio: "daily", "weekly", or "monthly"' },
        { name: "synchronization_mode", type: "string", description: 'The synchronization mode: "improv" or "orchestra"' },
        { name: "invitations", type: "string", description: 'Who can invite new members: "all_members" or "only_admins"' },
        { name: "representation", type: "string", description: 'Who can represent the studio: "any_member" or "only_representatives"' },
        { name: "file_uploads", type: "boolean", description: "Whether file attachments are allowed" },
        { name: "api_enabled", type: "boolean", description: "Whether API access is allowed (not changeable via API - use HTML UI to modify)" },
      ],
    },
    "add_subagent_to_studio" => {
      description: "Add one of your subagents to this studio",
      params_string: "(subagent_id)",
      params: [
        { name: "subagent_id", type: "integer", description: "ID of the subagent to add" },
      ],
    },
    "remove_subagent_from_studio" => {
      description: "Remove a subagent from this studio",
      params_string: "(subagent_id)",
      params: [
        { name: "subagent_id", type: "integer", description: "ID of the subagent to remove" },
      ],
    },
    "send_heartbeat" => {
      description: "Send a heartbeat to confirm your presence in the studio for this cycle",
      params_string: "()",
      params: [],
    },

    # Note actions
    "create_note" => {
      description: "Create a new note",
      params_string: "(text)",
      params: [
        { name: "text", type: "string", description: "The text of the note" },
      ],
    },
    "update_note" => {
      description: "Update this note",
      params_string: "(text)",
      params: [
        { name: "title", type: "string", description: "The updated title of the note" },
        { name: "text", type: "string", description: "The updated text of the note" },
        { name: "deadline", type: "datetime", description: "The updated deadline of the note" },
      ],
    },
    "confirm_read" => {
      description: "Confirm that you have read this note",
      params_string: "()",
      params: [],
    },
    "pin_note" => {
      description: "Pin this note to the studio homepage",
      params_string: "()",
      params: [],
    },
    "unpin_note" => {
      description: "Unpin this note from the studio homepage",
      params_string: "()",
      params: [],
    },

    # Decision actions
    "create_decision" => {
      description: "Create a new decision",
      params_string: "(question, description, options_open, deadline)",
      params: [
        { name: "question", type: "string", description: "The question being decided" },
        { name: "description", type: "string", description: "Additional context for the decision" },
        { name: "options_open", type: "boolean", description: "Whether participants can add options" },
        { name: "deadline", type: "datetime", description: "When the decision closes" },
      ],
    },
    "update_decision_settings" => {
      description: "Update the decision settings",
      params_string: "(question, description, options_open, deadline)",
      params: [
        { name: "question", type: "string", description: "The question being decided" },
        { name: "description", type: "string", description: "Additional context for the decision" },
        { name: "options_open", type: "boolean", description: "Whether participants can add options" },
        { name: "deadline", type: "datetime", description: "When the decision closes" },
      ],
    },
    "add_option" => {
      description: "Add an option to the options list",
      params_string: "(title)",
      params: [
        { name: "title", type: "string", description: "The title of the option" },
      ],
    },
    "vote" => {
      description: "Vote on an option",
      params_string: "(option_title, accept, prefer)",
      params: [
        { name: "option_title", type: "string", description: "The title of the option to vote on" },
        { name: "accept", type: "boolean", description: "Whether to accept this option" },
        { name: "prefer", type: "boolean", description: "Whether to prefer this option" },
      ],
    },
    "pin_decision" => {
      description: "Pin this decision to the studio homepage",
      params_string: "()",
      params: [],
    },
    "unpin_decision" => {
      description: "Unpin this decision from the studio homepage",
      params_string: "()",
      params: [],
    },

    # Commitment actions
    "create_commitment" => {
      description: "Create a new commitment",
      params_string: "(title, description, critical_mass, deadline)",
      params: [
        { name: "title", type: "string", description: "The title of the commitment" },
        { name: "description", type: "string", description: "Additional context for the commitment" },
        { name: "critical_mass", type: "integer", description: "Number of participants needed" },
        { name: "deadline", type: "datetime", description: "When the commitment closes" },
      ],
    },
    "update_commitment_settings" => {
      description: "Update the commitment settings",
      params_string: "(title, description, critical_mass, deadline)",
      params: [
        { name: "title", type: "string", description: "The title of the commitment" },
        { name: "description", type: "string", description: "Additional context for the commitment" },
        { name: "critical_mass", type: "integer", description: "Number of participants needed" },
        { name: "deadline", type: "datetime", description: "When the commitment closes" },
      ],
    },
    "join_commitment" => {
      description: "Join the commitment",
      params_string: "()",
      params: [],
    },
    "pin_commitment" => {
      description: "Pin this commitment to the studio homepage",
      params_string: "()",
      params: [],
    },
    "unpin_commitment" => {
      description: "Unpin this commitment from the studio homepage",
      params_string: "()",
      params: [],
    },

    # Comment action (shared across notes, decisions, commitments)
    "add_comment" => {
      description: "Add a comment",
      params_string: "(text)",
      params: [
        { name: "text", type: "string", description: "The text of the comment" },
      ],
    },

    # Attachment actions
    "add_attachment" => {
      description: "Add a file attachment",
      params_string: "(file)",
      params: [
        { name: "file", type: "object", description: "The file to attach (base64 encoded data with content_type and filename)" },
      ],
    },
    "remove_attachment" => {
      description: "Remove this attachment",
      params_string: "()",
      params: [],
    },

    # User settings actions
    "update_profile" => {
      description: "Update your profile name and/or handle",
      params_string: "(name, new_handle)",
      params: [
        { name: "name", type: "string", description: "Your display name" },
        { name: "new_handle", type: "string", description: "Your handle (used in URLs)" },
      ],
    },
    "create_api_token" => {
      description: "Create a new API token",
      params_string: "(name, read_write, duration, duration_unit)",
      params: [
        { name: "name", type: "string", description: "A name to identify this token" },
        { name: "read_write", type: "boolean", description: "Whether this token can write (true) or is read-only (false)" },
        { name: "duration", type: "integer", description: "How long the token is valid" },
        { name: "duration_unit", type: "string", description: 'Unit for duration: "days", "weeks", "months", or "years"' },
      ],
    },
    "create_subagent" => {
      description: "Create a new subagent",
      params_string: "(name, generate_token)",
      params: [
        { name: "name", type: "string", description: "The name of the subagent" },
        { name: "generate_token", type: "boolean", description: "Whether to generate an API token for the subagent" },
      ],
    },

    # Admin actions
    "update_tenant_settings" => {
      description: "Update tenant settings",
      params_string: "(name, timezone, api_enabled, require_login, allow_file_uploads)",
      params: [
        { name: "name", type: "string", description: "The name of the tenant" },
        { name: "timezone", type: "string", description: "The default timezone for the tenant" },
        { name: "api_enabled", type: "boolean", description: "Whether API access is enabled" },
        { name: "require_login", type: "boolean", description: "Whether login is required to view content" },
        { name: "allow_file_uploads", type: "boolean", description: "Whether file uploads are allowed" },
      ],
    },
    "create_tenant" => {
      description: "Create a new tenant",
      params_string: "(subdomain, name)",
      params: [
        { name: "subdomain", type: "string", description: "The subdomain for the new tenant" },
        { name: "name", type: "string", description: "The name of the new tenant" },
      ],
    },
    "retry_sidekiq_job" => {
      description: "Retry this Sidekiq job",
      params_string: "()",
      params: [],
    },

    # Notification actions
    "mark_read" => {
      description: "Mark a notification as read",
      params_string: "(id)",
      params: [
        { name: "id", type: "string", description: "The ID of the notification recipient to mark as read" },
      ],
    },
    "dismiss" => {
      description: "Dismiss a notification",
      params_string: "(id)",
      params: [
        { name: "id", type: "string", description: "The ID of the notification recipient to dismiss" },
      ],
    },
    "mark_all_read" => {
      description: "Mark all notifications as read",
      params_string: "()",
      params: [],
    },

    # Reminder actions
    "create_reminder" => {
      description: "Schedule a reminder notification for your future self",
      params_string: "(title, scheduled_for, body, url)",
      params: [
        { name: "title", type: "string", required: true, description: "The reminder text (max 255 chars)" },
        { name: "scheduled_for", type: "datetime", required: true, description: "When to deliver. Accepts: ISO 8601 datetime (2024-01-15T09:00:00Z), Unix timestamp (1705312800), or relative time (1h, 2d, 1w)" },
        { name: "body", type: "string", required: false, description: "Additional details (max 200 chars)" },
        { name: "url", type: "string", required: false, description: "A URL to include with the reminder" },
      ],
    },
    "delete_reminder" => {
      description: "Cancel a scheduled reminder before it triggers",
      params_string: "(id)",
      params: [
        { name: "id", type: "string", required: true, description: "The ID of the notification recipient to delete" },
      ],
    },

    # Webhook actions
    "create_webhook" => {
      description: "Create a new webhook",
      params_string: "(name, url, events, enabled)",
      params: [
        { name: "name", type: "string", description: "A descriptive name for this webhook" },
        { name: "url", type: "string", description: "The HTTPS URL to receive webhook payloads" },
        { name: "events", type: "array", description: "Event types to subscribe to (default: all)" },
        { name: "enabled", type: "boolean", description: "Whether the webhook is active (default: true)" },
      ],
    },
    "update_webhook" => {
      description: "Update a webhook",
      params_string: "(name, url, events, enabled)",
      params: [
        { name: "name", type: "string", description: "A descriptive name for this webhook" },
        { name: "url", type: "string", description: "The HTTPS URL to receive webhook payloads" },
        { name: "events", type: "array", description: "Event types to subscribe to" },
        { name: "enabled", type: "boolean", description: "Whether the webhook is active" },
      ],
    },
    "delete_webhook" => {
      description: "Delete a webhook",
      params_string: "()",
      params: [],
    },
    "test_webhook" => {
      description: "Send a test webhook",
      params_string: "()",
      params: [],
    },

    # User webhook actions
    "create_user_webhook" => {
      description: "Create a webhook for personal notifications (like reminders)",
      params_string: "(url, name, events)",
      params: [
        { name: "url", type: "string", description: "The HTTPS URL to receive webhook payloads" },
        { name: "name", type: "string", description: "A descriptive name for this webhook (optional)" },
        { name: "events", type: "array", description: 'Event types to subscribe to (default: ["reminders.delivered"])' },
      ],
    },
    "delete_user_webhook" => {
      description: "Delete a user webhook",
      params_string: "(id)",
      params: [
        { name: "id", type: "string", description: "The truncated ID of the webhook to delete" },
      ],
    },
  }.freeze

  # Route to actions mapping for actions index pages
  # This is derived from ACTION_DEFINITIONS but organized by route
  @@actions_by_route = {
    "/studios" => { actions: [] },
    "/studios/new" => {
      actions: [
        { name: "create_studio", params_string: ACTION_DEFINITIONS["create_studio"][:params_string], description: ACTION_DEFINITIONS["create_studio"][:description] },
      ],
    },
    "/studios/:studio_handle" => { actions: [] },
    "/studios/:studio_handle/join" => {
      actions: [
        { name: "join_studio", params_string: ACTION_DEFINITIONS["join_studio"][:params_string], description: ACTION_DEFINITIONS["join_studio"][:description] },
      ],
    },
    "/studios/:studio_handle/settings" => {
      actions: [
        { name: "update_studio_settings", params_string: ACTION_DEFINITIONS["update_studio_settings"][:params_string], description: ACTION_DEFINITIONS["update_studio_settings"][:description] },
        { name: "add_subagent_to_studio", params_string: ACTION_DEFINITIONS["add_subagent_to_studio"][:params_string], description: ACTION_DEFINITIONS["add_subagent_to_studio"][:description] },
        { name: "remove_subagent_from_studio", params_string: ACTION_DEFINITIONS["remove_subagent_from_studio"][:params_string], description: ACTION_DEFINITIONS["remove_subagent_from_studio"][:description] },
      ],
    },
    "/studios/:studio_handle/cycles" => { actions: [] },
    "/studios/:studio_handle/backlinks" => { actions: [] },
    "/studios/:studio_handle/team" => { actions: [] },
    "/studios/:studio_handle/note" => {
      actions: [
        { name: "create_note", params_string: ACTION_DEFINITIONS["create_note"][:params_string], description: ACTION_DEFINITIONS["create_note"][:description] },
      ],
    },
    "/studios/:studio_handle/n/:note_id" => {
      actions: [
        { name: "confirm_read", params_string: ACTION_DEFINITIONS["confirm_read"][:params_string], description: "Confirm that you have read the note" },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: "Add a comment to this note" },
      ],
    },
    "/studios/:studio_handle/n/:note_id/attachments/:attachment_id" => {
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/studios/:studio_handle/n/:note_id/edit" => {
      actions: [
        { name: "update_note", params_string: ACTION_DEFINITIONS["update_note"][:params_string], description: "Update the note" },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: "Add a file attachment to this note" },
      ],
    },
    "/studios/:studio_handle/decide" => {
      actions: [
        { name: "create_decision", params_string: ACTION_DEFINITIONS["create_decision"][:params_string], description: ACTION_DEFINITIONS["create_decision"][:description] },
      ],
    },
    "/studios/:studio_handle/d/:decision_id" => {
      actions: [
        { name: "add_option", params_string: ACTION_DEFINITIONS["add_option"][:params_string], description: ACTION_DEFINITIONS["add_option"][:description] },
        { name: "vote", params_string: ACTION_DEFINITIONS["vote"][:params_string], description: ACTION_DEFINITIONS["vote"][:description] },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: "Add a comment to this decision" },
      ],
    },
    "/studios/:studio_handle/d/:decision_id/attachments/:attachment_id" => {
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/studios/:studio_handle/d/:decision_id/settings" => {
      actions: [
        { name: "update_decision_settings", params_string: ACTION_DEFINITIONS["update_decision_settings"][:params_string], description: ACTION_DEFINITIONS["update_decision_settings"][:description] },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: "Add a file attachment to this decision" },
      ],
    },
    "/studios/:studio_handle/commit" => {
      actions: [
        { name: "create_commitment", params_string: ACTION_DEFINITIONS["create_commitment"][:params_string], description: ACTION_DEFINITIONS["create_commitment"][:description] },
      ],
    },
    "/studios/:studio_handle/c/:commitment_id" => {
      actions: [
        { name: "join_commitment", params_string: ACTION_DEFINITIONS["join_commitment"][:params_string], description: ACTION_DEFINITIONS["join_commitment"][:description] },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: "Add a comment to this commitment" },
      ],
    },
    "/studios/:studio_handle/c/:commitment_id/attachments/:attachment_id" => {
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/studios/:studio_handle/c/:commitment_id/settings" => {
      actions: [
        { name: "update_commitment_settings", params_string: ACTION_DEFINITIONS["update_commitment_settings"][:params_string], description: ACTION_DEFINITIONS["update_commitment_settings"][:description] },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: "Add a file attachment to this commitment" },
      ],
    },
    "/u/:handle/settings" => {
      actions: [
        { name: "update_profile", params_string: ACTION_DEFINITIONS["update_profile"][:params_string], description: ACTION_DEFINITIONS["update_profile"][:description] },
      ],
    },
    "/u/:handle/settings/tokens/new" => {
      actions: [
        { name: "create_api_token", params_string: ACTION_DEFINITIONS["create_api_token"][:params_string], description: ACTION_DEFINITIONS["create_api_token"][:description] },
      ],
    },
    "/u/:handle/settings/subagents/new" => {
      actions: [
        { name: "create_subagent", params_string: ACTION_DEFINITIONS["create_subagent"][:params_string], description: ACTION_DEFINITIONS["create_subagent"][:description] },
      ],
    },
    "/admin" => { actions: [] },
    "/admin/settings" => {
      actions: [
        { name: "update_tenant_settings", params_string: ACTION_DEFINITIONS["update_tenant_settings"][:params_string], description: ACTION_DEFINITIONS["update_tenant_settings"][:description] },
      ],
    },
    "/admin/tenants/new" => {
      actions: [
        { name: "create_tenant", params_string: ACTION_DEFINITIONS["create_tenant"][:params_string], description: ACTION_DEFINITIONS["create_tenant"][:description] },
      ],
    },
    "/admin/sidekiq/jobs/:jid" => {
      actions: [
        { name: "retry_sidekiq_job", params_string: ACTION_DEFINITIONS["retry_sidekiq_job"][:params_string], description: ACTION_DEFINITIONS["retry_sidekiq_job"][:description] },
      ],
    },
    "/notifications" => {
      actions: [
        { name: "mark_read", params_string: ACTION_DEFINITIONS["mark_read"][:params_string], description: ACTION_DEFINITIONS["mark_read"][:description] },
        { name: "dismiss", params_string: ACTION_DEFINITIONS["dismiss"][:params_string], description: ACTION_DEFINITIONS["dismiss"][:description] },
        { name: "mark_all_read", params_string: ACTION_DEFINITIONS["mark_all_read"][:params_string], description: ACTION_DEFINITIONS["mark_all_read"][:description] },
        { name: "create_reminder", params_string: ACTION_DEFINITIONS["create_reminder"][:params_string], description: ACTION_DEFINITIONS["create_reminder"][:description] },
        { name: "delete_reminder", params_string: ACTION_DEFINITIONS["delete_reminder"][:params_string], description: ACTION_DEFINITIONS["delete_reminder"][:description] },
      ],
    },
    "/studios/:studio_handle/settings/webhooks" => { actions: [] },
    "/studios/:studio_handle/settings/webhooks/new" => {
      actions: [
        { name: "create_webhook", params_string: ACTION_DEFINITIONS["create_webhook"][:params_string], description: ACTION_DEFINITIONS["create_webhook"][:description] },
      ],
    },
    "/studios/:studio_handle/settings/webhooks/:id" => {
      actions: [
        { name: "update_webhook", params_string: ACTION_DEFINITIONS["update_webhook"][:params_string], description: ACTION_DEFINITIONS["update_webhook"][:description] },
        { name: "delete_webhook", params_string: ACTION_DEFINITIONS["delete_webhook"][:params_string], description: ACTION_DEFINITIONS["delete_webhook"][:description] },
        { name: "test_webhook", params_string: ACTION_DEFINITIONS["test_webhook"][:params_string], description: ACTION_DEFINITIONS["test_webhook"][:description] },
      ],
    },
    "/u/:handle/settings/webhooks" => {
      actions: [
        { name: "create_user_webhook", params_string: ACTION_DEFINITIONS["create_user_webhook"][:params_string], description: ACTION_DEFINITIONS["create_user_webhook"][:description] },
        { name: "delete_user_webhook", params_string: ACTION_DEFINITIONS["delete_user_webhook"][:params_string], description: ACTION_DEFINITIONS["delete_user_webhook"][:description] },
      ],
    },
  }

  @@routes_and_actions = @@actions_by_route.keys.map do |route|
    {
      route: route,
      actions: @@actions_by_route[route][:actions],
    }
  end.sort_by { |item| item[:route] }

  # Get the full definition for an action
  # @param action_name [String] The name of the action
  # @return [Hash, nil] The action definition with description, params_string, and params
  sig { params(action_name: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.action_definition(action_name)
    ACTION_DEFINITIONS[action_name]
  end

  # Get action description ready for render_action_description
  # @param action_name [String] The name of the action
  # @param resource [Object, nil] The resource the action applies to
  # @param description_override [String, nil] Override the default description
  # @param params_override [Array, nil] Override the default params (for dynamic params)
  # @return [Hash] The action description hash
  sig do
    params(
      action_name: String,
      resource: T.untyped,
      description_override: T.nilable(String),
      params_override: T.nilable(T::Array[T::Hash[Symbol, T.untyped]])
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.action_description(action_name, resource: nil, description_override: nil, params_override: nil)
    definition = ACTION_DEFINITIONS[action_name]
    raise ArgumentError, "Unknown action: #{action_name}" unless definition

    {
      action_name: action_name,
      resource: resource,
      description: description_override || definition[:description],
      params: params_override || definition[:params],
    }
  end

  sig { returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
  def self.actions_by_route
    @@actions_by_route
  end

  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.routes_and_actions
    @@routes_and_actions
  end

  sig { params(route: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.actions_for_route(route)
    @@actions_by_route[route]
  end
end
