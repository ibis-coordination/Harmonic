# typed: true

# ActionsHelper is the single source of truth for all action definitions.
# Controllers should use this helper to get action descriptions and parameters
# rather than duplicating definitions in describe_* methods.
class ActionsHelper
  extend T::Sig

  # Authorization for actions restricted to "human" user types only.
  # AI agents and trustees cannot create other AI agents or API tokens.
  HUMAN_ONLY_AUTHORIZATION = T.let(
    lambda { |user, context|
      return false unless user
      return false unless user.user_type == "human"

      target_user = context[:target_user]
      target = context[:target]

      # No context = permissive for listing (show to person users)
      return true unless target_user || target

      # With context, check self or representative
      return true if target_user && target_user.id == user.id
      return true if target && user.can_represent?(target)

      false
    },
    T.proc.params(user: T.untyped, context: T::Hash[Symbol, T.untyped]).returns(T::Boolean)
  )

  # Context-aware webhook authorization.
  # - Collective webhooks require collective_admin
  # - User webhooks require self or representative access
  # - For listing (no context), allows authenticated users to see the action
  WEBHOOK_AUTHORIZATION = T.let(
    lambda { |user, context|
      return false unless user

      collective = context[:collective]
      target_user = context[:target_user]

      # If collective context exists and it's not the main collective, check collective_admin
      if collective && !collective.is_main_collective?
        member = user.collective_members.find_by(collective_id: collective.id)
        return member&.is_admin? || false
      end

      # For user webhooks, check self or representative
      if target_user
        return true if target_user.id == user.id

        return user.can_represent?(target_user)
      end

      # No specific context (e.g., for /actions listing) - allow authenticated users to see it
      true
    },
    T.proc.params(user: T.untyped, context: T::Hash[Symbol, T.untyped]).returns(T::Boolean)
  )

  # Authorization for table row operations — checks edit_access on the note.
  # When edit_access is "members", any collective member can edit.
  # When edit_access is "owner", only the note creator can edit.
  TABLE_CONTENT_EDIT_AUTHORIZATION = T.let(
    lambda { |user, context|
      return false unless user
      resource = context[:resource]
      return false unless resource.is_a?(Note) && resource.is_table?
      resource.user_can_edit_content?(user)
    },
    T.proc.params(user: T.untyped, context: T::Hash[Symbol, T.untyped]).returns(T::Boolean)
  )

  # Full action definitions with parameter details.
  # Each action has: description, params_string (for display), params (detailed param info),
  # and authorization (who can see/execute this action).
  #
  # Authorization can be:
  # - A symbol (e.g., :authenticated, :collective_member, :app_admin)
  # - An array of symbols (OR logic - any authorization suffices)
  # - A Proc for custom logic: ->(user, context) { ... }
  #
  # Actions without authorization are denied by default (fail-closed).
  #
  # @see ActionAuthorization for the authorization checker
  ACTION_DEFINITIONS = {
    # Collective actions
    "create_collective" => {
      description: "Create a new collective",
      params_string: "(name, handle, description, timezone, tempo, synchronization_mode, invitations, representation, file_uploads, api_enabled)",
      params: [
        { name: "name", type: "string", description: "The name of the collective" },
        { name: "handle", type: "string", description: "The handle of the collective (used in the URL)" },
        { name: "description", type: "string", description: "A description of the collective that will appear on the collective homepage" },
        { name: "timezone", type: "string", description: "The timezone of the collective" },
        { name: "tempo", type: "string", description: 'The tempo of the collective: "daily", "weekly", or "monthly"' },
        { name: "synchronization_mode", type: "string", description: 'The synchronization mode: "improv" or "orchestra"' },
        { name: "invitations", type: "string", description: 'Who can invite new members: "all_members" or "only_admins" (optional)' },
        { name: "representation", type: "string", description: 'Who can represent the collective: "any_member" or "only_representatives" (optional)' },
        { name: "file_uploads", type: "boolean", description: "Whether file attachments are allowed (optional)" },
        { name: "api_enabled", type: "boolean", description: "Whether API access is allowed (optional)" },
      ],
      authorization: :authenticated,
    },
    "join_collective" => {
      description: "Join the collective",
      params_string: "()",
      params: [
        { name: "code", type: "string", required: false, description: "Invite code" },
      ],
      authorization: :authenticated,
    },
    "update_collective_settings" => {
      description: "Update collective settings",
      params_string: "(name, description, timezone, tempo, synchronization_mode, invitations, representation, file_uploads, api_enabled)",
      params: [
        { name: "name", type: "string", description: "The name of the collective" },
        { name: "description", type: "string", description: "A description of the collective" },
        { name: "timezone", type: "string", description: "The timezone of the collective" },
        { name: "tempo", type: "string", description: 'The tempo of the collective: "daily", "weekly", or "monthly"' },
        { name: "synchronization_mode", type: "string", description: 'The synchronization mode: "improv" or "orchestra"' },
        { name: "invitations", type: "string", description: 'Who can invite new members: "all_members" or "only_admins"' },
        { name: "representation", type: "string", description: 'Who can represent the collective: "any_member" or "only_representatives"' },
        { name: "file_uploads", type: "boolean", description: "Whether file attachments are allowed" },
        { name: "api_enabled", type: "boolean", description: "Whether API access is allowed (not changeable via API - use HTML UI to modify)" },
      ],
      authorization: :collective_admin,
    },
    "add_ai_agent_to_collective" => {
      description: "Add one of your AI agents to this collective",
      params_string: "(ai_agent_id)",
      params: [
        { name: "ai_agent_id", type: "integer", description: "ID of the AI agent to add" },
      ],
      authorization: :collective_admin,
    },
    "remove_ai_agent_from_collective" => {
      description: "Remove an AI agent from this collective",
      params_string: "(ai_agent_id)",
      params: [
        { name: "ai_agent_id", type: "integer", description: "ID of the AI agent to remove" },
      ],
      authorization: :collective_admin,
    },
    "send_heartbeat" => {
      description: "Send a heartbeat to confirm your presence in the collective for this cycle",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },

    # Note actions
    "create_note" => {
      description: "Create a new note",
      params_string: "(text)",
      params: [
        { name: "text", type: "string", description: "The text of the note" },
      ],
      authorization: :collective_member,
    },
    "update_note" => {
      description: "Update this note",
      params_string: "(text)",
      params: [
        { name: "title", type: "string", description: "The updated title of the note" },
        { name: "text", type: "string", description: "The updated text of the note" },
        { name: "deadline", type: "datetime", description: "The updated deadline of the note" },
      ],
      authorization: :resource_owner,
    },
    "confirm_read" => {
      description: "Confirm that you have read this note",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "create_reminder_note" => {
      description: "Create a reminder note that resurfaces in the feed at a scheduled time",
      params_string: "(text, scheduled_for, title)",
      params: [
        { name: "text", type: "string", required: true, description: "The reminder content" },
        { name: "scheduled_for", type: "datetime", required: true, description: "When to deliver. Accepts: ISO 8601 datetime (2024-01-15T09:00:00Z), Unix timestamp (1705312800), or relative time (1h, 2d, 1w)" },
        { name: "title", type: "string", required: false, description: "Optional title for the reminder note" },
      ],
      authorization: :collective_member,
    },
    "cancel_reminder" => {
      description: "Cancel a pending reminder on this note",
      params_string: "()",
      params: [],
      authorization: :owner,
    },
    "acknowledge_reminder" => {
      description: "Acknowledge that you have seen this reminder",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "create_table_note" => {
      description: "Create a new table note with columns defined upfront",
      params_string: "(title, columns, description, edit_access)",
      params: [
        { name: "title", type: "string", description: "The title of the table" },
        { name: "columns", type: "array", description: 'Array of column definitions, e.g. [{ "name": "Status", "type": "text" }, { "name": "Due", "type": "date" }]. Types: text, number, boolean, date' },
        { name: "initial_rows", type: "array", required: false, description: 'Array of row objects with column name/value pairs, e.g. [{ "Status": "done", "Due": "2026-05-01" }]' },
        { name: "description", type: "string", required: false, description: "Description of what the table is for" },
        { name: "edit_access", type: "string", required: false, description: "Who can edit rows: 'owner' (default) or 'members'" },
      ],
      authorization: :collective_member,
    },
    # Table note actions
    "add_row" => {
      description: "Add a row to this table",
      params_string: "(column values)",
      params: [
        { name: "values", type: "object", description: "Column name/value pairs, e.g. { \"Status\": \"done\", \"Due\": \"2026-05-01\" }" },
      ],
      authorization: TABLE_CONTENT_EDIT_AUTHORIZATION,
    },
    "update_row" => {
      description: "Update a row in this table",
      params_string: "(row_id, column values)",
      params: [
        { name: "row_id", type: "string", description: "The _id of the row to update" },
        { name: "values", type: "object", description: "Column name/value pairs to update (partial update)" },
      ],
      authorization: TABLE_CONTENT_EDIT_AUTHORIZATION,
    },
    "delete_row" => {
      description: "Delete a row from this table",
      params_string: "(row_id)",
      params: [
        { name: "row_id", type: "string", description: "The _id of the row to delete" },
      ],
      authorization: TABLE_CONTENT_EDIT_AUTHORIZATION,
    },
    "add_table_column" => {
      description: "Add a column to this table",
      params_string: "(name, type)",
      params: [
        { name: "name", type: "string", description: "Column name (alphanumeric, spaces, underscores)" },
        { name: "type", type: "string", description: "Column type: text, number, boolean, or date" },
      ],
      authorization: :resource_owner,
    },
    "remove_table_column" => {
      description: "Remove a column from this table (deletes all values in that column)",
      params_string: "(name)",
      params: [
        { name: "name", type: "string", description: "Name of the column to remove" },
      ],
      authorization: :resource_owner,
    },
    "query_rows" => {
      description: "Query rows in this table with optional filtering, sorting, and pagination",
      params_string: "(where, order_by, order, limit, offset)",
      params: [
        { name: "where", type: "object", required: false, description: "Filter by column values, e.g. { \"Status\": \"done\" }" },
        { name: "order_by", type: "string", required: false, description: "Column name to sort by" },
        { name: "order", type: "string", required: false, description: "Sort direction: asc or desc (default: asc)" },
        { name: "limit", type: "integer", required: false, description: "Max rows to return (default: 20)" },
        { name: "offset", type: "integer", required: false, description: "Number of rows to skip (default: 0)" },
      ],
      authorization: :collective_member,
    },
    "summarize" => {
      description: "Compute an aggregate over rows in this table",
      params_string: "(operation, column, where)",
      params: [
        { name: "operation", type: "string", description: "Operation: count, sum, average, min, or max" },
        { name: "column", type: "string", required: false, description: "Column to aggregate (required for sum/average/min/max)" },
        { name: "where", type: "object", required: false, description: "Filter by column values before aggregating" },
      ],
      authorization: :collective_member,
    },
    "update_table_description" => {
      description: "Update the description of this table",
      params_string: "(description)",
      params: [
        { name: "description", type: "string", description: "New description text" },
      ],
      authorization: :resource_owner,
    },
    "batch_table_update" => {
      description: "Perform multiple table operations in a single request (one save, one event)",
      params_string: "(operations)",
      params: [
        { name: "operations", type: "array", description: 'Array of operations, e.g. [{ "action": "add_row", "values": { "Status": "done" } }, { "action": "delete_row", "row_id": "abc123" }]. Valid actions: add_row, update_row, delete_row, add_table_column, remove_table_column, update_table_description' },
      ],
      authorization: TABLE_CONTENT_EDIT_AUTHORIZATION,
    },
    "pin_note" => {
      description: "Pin this note to the collective homepage",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "unpin_note" => {
      description: "Unpin this note from the collective homepage",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "delete_note" => {
      description: "Delete this note. Comments from others will be preserved.",
      params_string: "()",
      params: [],
      authorization: [:resource_owner, :collective_admin, :app_admin],
    },
    "report_content" => {
      description: "Report this content for moderator review",
      params_string: "(reason, description, also_block)",
      params: [
        { name: "reason", type: "string", description: "Reason for reporting: harassment, spam, inappropriate, misinformation, or other" },
        { name: "description", type: "string", description: "Additional context for moderators (optional)" },
        { name: "also_block", type: "string", description: 'Set to "1" to also block the author (optional)' },
      ],
      authorization: :authenticated,
    },

    # Decision actions
    "create_decision" => {
      description: "Create a new decision. Use subtype 'executive' for executive decisions where a designated decision maker selects options and issues a final statement instead of group voting.",
      params_string: "(question, description, options_open, deadline, subtype, decision_maker)",
      params: [
        { name: "question", type: "string", description: "The question being decided" },
        { name: "description", type: "string", description: "Additional context for the decision" },
        { name: "options_open", type: "boolean", description: "Whether participants can add options" },
        { name: "deadline", type: "datetime", description: "When the decision closes" },
        { name: "subtype", type: "string", required: false, description: "Decision subtype: 'vote' (default) or 'executive'" },
        { name: "decision_maker", type: "string", required: false, description: "For executive decisions: handle (e.g. '@dan') or user ID of the decision maker (defaults to creator)" },
      ],
      authorization: :collective_member,
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
      authorization: :resource_owner,
    },
    "add_options" => {
      description: "Add one or more options to the decision",
      params_string: "(titles)",
      params: [
        { name: "titles", type: "array[string]", description: "Array of option title strings" },
      ],
      authorization: :collective_member,
    },
    "vote" => {
      description: "Vote on one or more options",
      params_string: "(votes)",
      params: [
        { name: "votes", type: "array[object]", description: "Array of vote objects, each with: option_title (string), accept (boolean), prefer (boolean)" },
      ],
      authorization: :collective_member,
    },
    "pin_decision" => {
      description: "Pin this decision to the collective homepage",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "unpin_decision" => {
      description: "Unpin this decision from the collective homepage",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "close_decision" => {
      description: "Close this decision immediately, ending voting. Optionally include a final statement explaining the outcome. For executive decisions, include selections to indicate which options were selected.",
      params_string: "(final_statement, selections)",
      params: [
        { name: "final_statement", type: "string", required: false, description: "Optional final statement explaining the outcome" },
        { name: "selections", type: "array", required: false, description: "For executive decisions: array of option titles to mark as selected" },
      ],
      authorization: :resource_owner,
    },
    "add_statement" => {
      description: "Add or update the final statement on this decision. Only available after the decision is closed.",
      params_string: "(text)",
      params: [
        { name: "text", type: "string", description: "The statement text" },
      ],
      authorization: :resource_owner,
    },
    "delete_decision" => {
      description: "Delete this decision. Votes and comments from others will be preserved.",
      params_string: "()",
      params: [],
      authorization: [:resource_owner, :collective_admin, :app_admin],
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
      authorization: :collective_member,
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
      authorization: :resource_owner,
    },
    "join_commitment" => {
      description: "Join the commitment",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "pin_commitment" => {
      description: "Pin this commitment to the collective homepage",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "unpin_commitment" => {
      description: "Unpin this commitment from the collective homepage",
      params_string: "()",
      params: [],
      authorization: :collective_member,
    },
    "delete_commitment" => {
      description: "Delete this commitment. Participant records and comments from others will be preserved.",
      params_string: "()",
      params: [],
      authorization: [:resource_owner, :collective_admin, :app_admin],
    },

    # Comment action (shared across notes, decisions, commitments)
    "add_comment" => {
      description: "Add a comment",
      params_string: "(text)",
      params: [
        { name: "text", type: "string", description: "The text of the comment" },
      ],
      authorization: :collective_member,
    },

    # Attachment actions
    "add_attachment" => {
      description: "Add a file attachment",
      params_string: "(file)",
      params: [
        { name: "file", type: "object", description: "The file to attach (base64 encoded data with content_type and filename)" },
      ],
      authorization: :resource_owner,
    },
    "remove_attachment" => {
      description: "Remove this attachment",
      params_string: "()",
      params: [],
      authorization: :resource_owner,
    },

    # User settings actions
    "update_profile" => {
      description: "Update your profile name and/or handle",
      params_string: "(name, new_handle)",
      params: [
        { name: "name", type: "string", description: "Your display name" },
        { name: "new_handle", type: "string", description: "Your handle (used in URLs)" },
      ],
      authorization: [:self, :representative],
    },
    "update_scratchpad" => {
      description: "Update your scratchpad with notes for your future self",
      params_string: "(content)",
      params: [
        { name: "content", type: "string", description: "The new scratchpad content (max 10000 chars). Replaces existing content." },
      ],
      authorization: :self_ai_agent,
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
      authorization: HUMAN_ONLY_AUTHORIZATION,
    },
    "create_ai_agent" => {
      description: "Create a new AI agent",
      params_string: "(name, identity_prompt, generate_token)",
      params: [
        { name: "name", type: "string", description: "The name of the AI agent" },
        { name: "identity_prompt", type: "string", description: "A prompt shown to the agent on /whoami, providing context about their identity and purpose" },
        { name: "generate_token", type: "boolean", description: "Whether to generate an API token for the AI agent" },
      ],
      authorization: HUMAN_ONLY_AUTHORIZATION,
    },

    # Admin actions
    "update_tenant_settings" => {
      description: "Update tenant settings",
      params_string: "(name, timezone, api_enabled, require_login, allow_file_uploads, allowed_attachment_categories)",
      params: [
        { name: "name", type: "string", description: "The name of the tenant" },
        { name: "timezone", type: "string", description: "The default timezone for the tenant" },
        { name: "api_enabled", type: "boolean", description: "Whether API access is enabled" },
        { name: "require_login", type: "boolean", description: "Whether login is required to view content" },
        { name: "allow_file_uploads", type: "boolean", description: "Whether file uploads are allowed" },
        { name: "allowed_attachment_categories", type: "array[string]", description: "Categories of attachment content types that may be uploaded. Valid values: images, pdfs, text. Send the full desired set; values not in the list are dropped." },
      ],
      authorization: :tenant_admin,
    },
    "create_tenant" => {
      description: "Create a new tenant",
      params_string: "(subdomain, name)",
      params: [
        { name: "subdomain", type: "string", description: "The subdomain for the new tenant" },
        { name: "name", type: "string", description: "The name of the new tenant" },
      ],
      authorization: :app_admin,
    },
    "retry_sidekiq_job" => {
      description: "Retry this Sidekiq job",
      params_string: "()",
      params: [],
      authorization: :system_admin,
    },
    "suspend_user" => {
      description: "Suspend this user's account, preventing them from logging in",
      params_string: "(reason)",
      params: [
        { name: "reason", type: "string", required: true, description: "The reason for suspension (will be shown to the user)" },
      ],
      authorization: :app_admin,
    },
    "unsuspend_user" => {
      description: "Unsuspend this user's account, restoring their access",
      params_string: "()",
      params: [],
      authorization: :app_admin,
    },

    # Search actions
    "search" => {
      description: "Search for items matching a query",
      params_string: "(q)",
      params: [
        {
          name: "q",
          type: "string",
          required: true,
          description: "The search query. Supports operators: type:, status:, cycle:, creator:, collective:, etc.",
        },
      ],
      authorization: :authenticated,
    },

    # Notification actions
    "dismiss" => {
      description: "Dismiss a notification",
      params_string: "(id)",
      params: [
        { name: "id", type: "string", description: "The ID of the notification recipient to dismiss" },
      ],
      authorization: :authenticated,
    },
    "dismiss_all" => {
      description: "Dismiss all notifications",
      params_string: "()",
      params: [],
      authorization: :authenticated,
    },
    "dismiss_for_collective" => {
      description: "Dismiss all notifications for a specific collective",
      params_string: "(collective_id)",
      params: [
        { name: "collective_id", type: "string", description: "The ID of the collective, or 'reminders' to dismiss due reminders" },
      ],
      authorization: :authenticated,
    },

    # Webhook actions
    # Webhooks can be created for collectives (requires collective_admin) or users (requires self/representative).
    # Authorization is context-aware: checks collective context first, then falls back to user context.
    "create_webhook" => {
      description: "Create a new webhook",
      params_string: "(name, url, events, enabled)",
      params: [
        { name: "name", type: "string", description: "A descriptive name for this webhook" },
        { name: "url", type: "string", description: "The HTTPS URL to receive webhook payloads" },
        { name: "events", type: "array", description: "Event types to subscribe to (default: all)" },
        { name: "enabled", type: "boolean", description: "Whether the webhook is active (default: true)" },
      ],
      authorization: WEBHOOK_AUTHORIZATION,
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
      authorization: WEBHOOK_AUTHORIZATION,
    },
    "delete_webhook" => {
      description: "Delete a webhook",
      params_string: "()",
      params: [],
      authorization: WEBHOOK_AUTHORIZATION,
    },
    "test_webhook" => {
      description: "Send a test webhook",
      params_string: "()",
      params: [],
      authorization: WEBHOOK_AUTHORIZATION,
    },

    # Automation Rule actions
    "create_automation_rule" => {
      description: "Create a new automation rule from YAML configuration",
      params_string: "(yaml_source)",
      params: [
        { name: "yaml_source", type: "string", required: true, description: "The YAML configuration for the automation rule" },
      ],
      authorization: HUMAN_ONLY_AUTHORIZATION,
    },
    "update_automation_rule" => {
      description: "Update an automation rule's YAML configuration",
      params_string: "(yaml_source)",
      params: [
        { name: "yaml_source", type: "string", required: true, description: "The updated YAML configuration for the automation rule" },
      ],
      authorization: HUMAN_ONLY_AUTHORIZATION,
    },
    "delete_automation_rule" => {
      description: "Delete an automation rule",
      params_string: "()",
      params: [],
      authorization: HUMAN_ONLY_AUTHORIZATION,
    },
    "toggle_automation_rule" => {
      description: "Enable or disable an automation rule",
      params_string: "()",
      params: [],
      authorization: HUMAN_ONLY_AUTHORIZATION,
    },

    # Trustee Grant actions
    "create_trustee_grant" => {
      description: "Grant another user authority to act on your behalf",
      params_string: "(trustee_user_id, permissions, collective_scope_mode, collective_ids, expires_at)",
      params: [
        { name: "trustee_user_id", type: "string", required: true, description: "The ID of the user to grant trustee authority to" },
        { name: "permissions", type: "array", required: true, description: "Array of capability names to grant (e.g., create_notes, vote, commit)" },
        { name: "collective_scope_mode", type: "string", description: 'Collective scope mode: "all" (default), "include", or "exclude"' },
        { name: "collective_ids", type: "array", description: "Array of collective IDs for include/exclude modes" },
        { name: "expires_at", type: "datetime", description: "When the trustee grant expires (optional)" },
      ],
      authorization: :self,
    },
    "accept_trustee_grant" => {
      description: "Accept a trustee grant request",
      params_string: "()",
      params: [],
      authorization: :self,
    },
    "decline_trustee_grant" => {
      description: "Decline a trustee grant request",
      params_string: "()",
      params: [],
      authorization: :self,
    },
    "revoke_trustee_grant" => {
      description: "Revoke a trustee grant you previously created",
      params_string: "()",
      params: [],
      authorization: :self,
    },
    "start_representation" => {
      description: "Start a representation session to act on behalf of the granting user",
      params_string: "()",
      params: [],
      authorization: :self,
    },
    "end_representation" => {
      description: "End an active representation session for this grant",
      params_string: "()",
      params: [],
      authorization: :self,
    },
  }.freeze

  # Route to actions mapping for actions index pages.
  # This is derived from ACTION_DEFINITIONS but organized by route.
  #
  # Each entry includes:
  # - controller_actions: Array of "controller#action" strings that map to this route pattern.
  #   Multiple controller#actions can map to the same route pattern (e.g., collectives#show and collectives#cycles).
  # - actions: Array of action definitions available at this route.
  #
  # The controller_actions mapping is the single source of truth for route pattern resolution.
  # MarkdownHelper.build_route_pattern_from_request uses this to look up route patterns.

  # Shared condition for report_content conditional action.
  # Shows the action only when the user is not the content author and hasn't already reported it.
  TABLE_NOTE_CONDITION = ->(context) {
    resource = context[:resource]
    resource.is_a?(Note) && resource.is_table?
  }

  PENDING_REMINDER_CONDITION = ->(context) {
    resource = context[:resource]
    resource.is_a?(Note) && resource.is_reminder? && resource.reminder_pending?
  }

  DELIVERED_REMINDER_CONDITION = ->(context) {
    resource = context[:resource]
    resource.is_a?(Note) && resource.is_reminder? && resource.reminder_delivered?
  }

  # confirm_read is available for all notes EXCEPT delivered reminder notes
  CONFIRM_READ_CONDITION = ->(context) {
    resource = context[:resource]
    return true unless resource.is_a?(Note)
    !(resource.is_reminder? && resource.reminder_delivered?)
  }

  REPORT_CONTENT_CONDITION = ->(context) {
    user = context[:user]
    resource = context[:resource]
    user && resource && resource.respond_to?(:created_by_id) &&
      resource.created_by_id != user.id &&
      !ContentReport.where(reporter: user, reportable: resource).exists?
  }

  @@actions_by_route = {
    "/" => {
      controller_actions: ["home#index"],
      actions: [],
    },
    "/whoami" => {
      controller_actions: ["whoami#index"],
      actions: [
        { name: "update_scratchpad", params_string: ACTION_DEFINITIONS["update_scratchpad"][:params_string], description: ACTION_DEFINITIONS["update_scratchpad"][:description] },
      ],
    },
    "/collectives" => {
      controller_actions: ["collectives#index"],
      actions: [],
    },
    "/collectives/new" => {
      controller_actions: ["collectives#new"],
      actions: [
        { name: "create_collective", params_string: ACTION_DEFINITIONS["create_collective"][:params_string], description: ACTION_DEFINITIONS["create_collective"][:description] },
      ],
    },
    "/collectives/:collective_handle" => {
      controller_actions: ["pulse#show"],
      actions: [],
      conditional_actions: [
        {
          name: "send_heartbeat",
          condition: ->(context) {
            collective = context[:collective]
            current_heartbeat = context[:current_heartbeat]
            collective && !collective.is_main_collective? && !collective.private_workspace? && current_heartbeat.nil?
          },
        },
      ],
    },
    "/collectives/:collective_handle/actions" => {
      controller_actions: ["pulse#actions_index"],
      actions: [],
      conditional_actions: [
        {
          name: "send_heartbeat",
          condition: ->(context) {
            collective = context[:collective]
            current_heartbeat = context[:current_heartbeat]
            collective && !collective.is_main_collective? && !collective.private_workspace? && current_heartbeat.nil?
          },
        },
      ],
    },
    "/collectives/:collective_handle/join" => {
      controller_actions: ["collectives#join"],
      actions: [
        { name: "join_collective", params_string: ACTION_DEFINITIONS["join_collective"][:params_string], description: ACTION_DEFINITIONS["join_collective"][:description] },
      ],
    },
    "/collectives/:collective_handle/settings" => {
      controller_actions: ["collectives#settings"],
      actions: [
        { name: "update_collective_settings", params_string: ACTION_DEFINITIONS["update_collective_settings"][:params_string], description: ACTION_DEFINITIONS["update_collective_settings"][:description] },
        { name: "add_ai_agent_to_collective", params_string: ACTION_DEFINITIONS["add_ai_agent_to_collective"][:params_string], description: ACTION_DEFINITIONS["add_ai_agent_to_collective"][:description] },
        { name: "remove_ai_agent_from_collective", params_string: ACTION_DEFINITIONS["remove_ai_agent_from_collective"][:params_string], description: ACTION_DEFINITIONS["remove_ai_agent_from_collective"][:description] },
      ],
    },
    "/collectives/:collective_handle/cycles" => {
      controller_actions: ["cycles#index"],
      actions: [],
      conditional_actions: [
        {
          name: "send_heartbeat",
          condition: ->(context) {
            collective = context[:collective]
            current_heartbeat = context[:current_heartbeat]
            collective && !collective.is_main_collective? && !collective.private_workspace? && current_heartbeat.nil?
          },
        },
      ],
    },
    "/collectives/:collective_handle/backlinks" => {
      controller_actions: ["collectives#backlinks"],
      actions: [],
    },
    "/collectives/:collective_handle/members" => {
      controller_actions: ["collectives#members"],
      actions: [],
    },
    "/collectives/:collective_handle/note" => {
      controller_actions: ["notes#new"],
      actions: [
        { name: "create_note", params_string: ACTION_DEFINITIONS["create_note"][:params_string], description: ACTION_DEFINITIONS["create_note"][:description] },
        { name: "create_reminder_note", params_string: ACTION_DEFINITIONS["create_reminder_note"][:params_string], description: ACTION_DEFINITIONS["create_reminder_note"][:description] },
        { name: "create_table_note", params_string: ACTION_DEFINITIONS["create_table_note"][:params_string], description: ACTION_DEFINITIONS["create_table_note"][:description] },
      ],
    },
    "/collectives/:collective_handle/n/:note_id" => {
      controller_actions: ["notes#show"],
      actions: [
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: ACTION_DEFINITIONS["add_comment"][:description] },
      ],
      conditional_actions: [
        {
          name: "confirm_read",
          params_string: ACTION_DEFINITIONS["confirm_read"][:params_string],
          description: ACTION_DEFINITIONS["confirm_read"][:description],
          condition: CONFIRM_READ_CONDITION,
        },
        {
          name: "acknowledge_reminder",
          params_string: ACTION_DEFINITIONS["acknowledge_reminder"][:params_string],
          description: ACTION_DEFINITIONS["acknowledge_reminder"][:description],
          condition: DELIVERED_REMINDER_CONDITION,
        },
        {
          name: "cancel_reminder",
          params_string: ACTION_DEFINITIONS["cancel_reminder"][:params_string],
          description: ACTION_DEFINITIONS["cancel_reminder"][:description],
          condition: PENDING_REMINDER_CONDITION,
        },
        {
          name: "report_content",
          params_string: ACTION_DEFINITIONS["report_content"][:params_string],
          description: ACTION_DEFINITIONS["report_content"][:description],
          condition: REPORT_CONTENT_CONDITION,
        },
        {
          name: "add_row",
          params_string: ACTION_DEFINITIONS["add_row"][:params_string],
          description: ACTION_DEFINITIONS["add_row"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "update_row",
          params_string: ACTION_DEFINITIONS["update_row"][:params_string],
          description: ACTION_DEFINITIONS["update_row"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "delete_row",
          params_string: ACTION_DEFINITIONS["delete_row"][:params_string],
          description: ACTION_DEFINITIONS["delete_row"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "add_table_column",
          params_string: ACTION_DEFINITIONS["add_table_column"][:params_string],
          description: ACTION_DEFINITIONS["add_table_column"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "remove_table_column",
          params_string: ACTION_DEFINITIONS["remove_table_column"][:params_string],
          description: ACTION_DEFINITIONS["remove_table_column"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "query_rows",
          params_string: ACTION_DEFINITIONS["query_rows"][:params_string],
          description: ACTION_DEFINITIONS["query_rows"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "summarize",
          params_string: ACTION_DEFINITIONS["summarize"][:params_string],
          description: ACTION_DEFINITIONS["summarize"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "update_table_description",
          params_string: ACTION_DEFINITIONS["update_table_description"][:params_string],
          description: ACTION_DEFINITIONS["update_table_description"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
        {
          name: "batch_table_update",
          params_string: ACTION_DEFINITIONS["batch_table_update"][:params_string],
          description: ACTION_DEFINITIONS["batch_table_update"][:description],
          condition: TABLE_NOTE_CONDITION,
        },
      ],
    },
    "/collectives/:collective_handle/n/:note_id/attachments/:attachment_id" => {
      controller_actions: ["attachments#show"],
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/collectives/:collective_handle/n/:note_id/edit" => {
      controller_actions: ["notes#edit"],
      actions: [
        { name: "update_note", params_string: ACTION_DEFINITIONS["update_note"][:params_string], description: ACTION_DEFINITIONS["update_note"][:description] },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: ACTION_DEFINITIONS["add_attachment"][:description] },
      ],
    },
    "/collectives/:collective_handle/n/:note_id/settings" => {
      controller_actions: ["notes#settings"],
      actions: [],
    },
    "/collectives/:collective_handle/decide" => {
      controller_actions: ["decisions#new"],
      actions: [
        { name: "create_decision", params_string: ACTION_DEFINITIONS["create_decision"][:params_string], description: ACTION_DEFINITIONS["create_decision"][:description] },
      ],
    },
    "/collectives/:collective_handle/d/:decision_id" => {
      controller_actions: ["decisions#show"],
      actions: [
        { name: "add_options", params_string: ACTION_DEFINITIONS["add_options"][:params_string], description: ACTION_DEFINITIONS["add_options"][:description] },
        { name: "vote", params_string: ACTION_DEFINITIONS["vote"][:params_string], description: ACTION_DEFINITIONS["vote"][:description] },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: ACTION_DEFINITIONS["add_comment"][:description] },
        { name: "close_decision", params_string: ACTION_DEFINITIONS["close_decision"][:params_string], description: ACTION_DEFINITIONS["close_decision"][:description] },
        { name: "add_statement", params_string: ACTION_DEFINITIONS["add_statement"][:params_string], description: ACTION_DEFINITIONS["add_statement"][:description] },
      ],
      conditional_actions: [
        {
          name: "report_content",
          params_string: ACTION_DEFINITIONS["report_content"][:params_string],
          description: ACTION_DEFINITIONS["report_content"][:description],
          condition: REPORT_CONTENT_CONDITION,
        },
      ],
    },
    "/collectives/:collective_handle/d/:decision_id/attachments/:attachment_id" => {
      controller_actions: ["attachments#show"],
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/collectives/:collective_handle/d/:decision_id/settings" => {
      controller_actions: ["decisions#settings"],
      actions: [
        { name: "update_decision_settings", params_string: ACTION_DEFINITIONS["update_decision_settings"][:params_string], description: ACTION_DEFINITIONS["update_decision_settings"][:description] },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: ACTION_DEFINITIONS["add_attachment"][:description] },
      ],
    },
    "/collectives/:collective_handle/commit" => {
      controller_actions: ["commitments#new"],
      actions: [
        { name: "create_commitment", params_string: ACTION_DEFINITIONS["create_commitment"][:params_string], description: ACTION_DEFINITIONS["create_commitment"][:description] },
      ],
    },
    "/collectives/:collective_handle/c/:commitment_id" => {
      controller_actions: ["commitments#show"],
      actions: [
        { name: "join_commitment", params_string: ACTION_DEFINITIONS["join_commitment"][:params_string], description: ACTION_DEFINITIONS["join_commitment"][:description] },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: ACTION_DEFINITIONS["add_comment"][:description] },
      ],
      conditional_actions: [
        {
          name: "report_content",
          params_string: ACTION_DEFINITIONS["report_content"][:params_string],
          description: ACTION_DEFINITIONS["report_content"][:description],
          condition: REPORT_CONTENT_CONDITION,
        },
      ],
    },
    "/collectives/:collective_handle/c/:commitment_id/attachments/:attachment_id" => {
      controller_actions: ["attachments#show"],
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/collectives/:collective_handle/c/:commitment_id/settings" => {
      controller_actions: ["commitments#settings"],
      actions: [
        { name: "update_commitment_settings", params_string: ACTION_DEFINITIONS["update_commitment_settings"][:params_string], description: ACTION_DEFINITIONS["update_commitment_settings"][:description] },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: ACTION_DEFINITIONS["add_attachment"][:description] },
      ],
    },
    "/u/:handle/settings" => {
      controller_actions: ["users#settings"],
      actions: [
        { name: "update_profile", params_string: ACTION_DEFINITIONS["update_profile"][:params_string], description: ACTION_DEFINITIONS["update_profile"][:description] },
      ],
    },
    "/u/:handle/settings/tokens/new" => {
      controller_actions: ["api_tokens#new"],
      actions: [
        { name: "create_api_token", params_string: ACTION_DEFINITIONS["create_api_token"][:params_string], description: ACTION_DEFINITIONS["create_api_token"][:description] },
      ],
    },
    "/ai-agents" => {
      controller_actions: ["ai_agents#index"],
      actions: [],
    },
    "/ai-agents/new" => {
      controller_actions: ["ai_agents#new"],
      actions: [
        { name: "create_ai_agent", params_string: ACTION_DEFINITIONS["create_ai_agent"][:params_string], description: ACTION_DEFINITIONS["create_ai_agent"][:description] },
      ],
    },
    "/ai-agents/:handle" => {
      controller_actions: ["ai_agents#show"],
      actions: [],
    },
    "/ai-agents/:handle/settings" => {
      controller_actions: ["ai_agents#settings"],
      actions: [
        { name: "update_profile", params_string: ACTION_DEFINITIONS["update_profile"][:params_string], description: ACTION_DEFINITIONS["update_profile"][:description] },
      ],
    },
    "/admin" => {
      controller_actions: ["admin#index", "tenant_admin#index"],
      actions: [],
    },
    "/admin/settings" => {
      controller_actions: ["admin#settings", "tenant_admin#settings"],
      actions: [
        { name: "update_tenant_settings", params_string: ACTION_DEFINITIONS["update_tenant_settings"][:params_string], description: ACTION_DEFINITIONS["update_tenant_settings"][:description] },
      ],
    },
    "/admin/tenants/new" => {
      controller_actions: ["app_admin#new_tenant"],
      actions: [
        { name: "create_tenant", params_string: ACTION_DEFINITIONS["create_tenant"][:params_string], description: ACTION_DEFINITIONS["create_tenant"][:description] },
      ],
    },
    "/admin/sidekiq/jobs/:jid" => {
      controller_actions: ["system_admin#show_job"],
      actions: [
        { name: "retry_sidekiq_job", params_string: ACTION_DEFINITIONS["retry_sidekiq_job"][:params_string], description: ACTION_DEFINITIONS["retry_sidekiq_job"][:description] },
      ],
    },
    "/admin/users/:handle" => {
      controller_actions: ["system_admin#show_user"],
      actions: [
        { name: "suspend_user", params_string: ACTION_DEFINITIONS["suspend_user"][:params_string], description: ACTION_DEFINITIONS["suspend_user"][:description] },
        { name: "unsuspend_user", params_string: ACTION_DEFINITIONS["unsuspend_user"][:params_string], description: ACTION_DEFINITIONS["unsuspend_user"][:description] },
      ],
    },
    "/notifications" => {
      controller_actions: ["notifications#index"],
      actions: [
        { name: "dismiss", params_string: ACTION_DEFINITIONS["dismiss"][:params_string], description: ACTION_DEFINITIONS["dismiss"][:description] },
        { name: "dismiss_all", params_string: ACTION_DEFINITIONS["dismiss_all"][:params_string], description: ACTION_DEFINITIONS["dismiss_all"][:description] },
        { name: "dismiss_for_collective", params_string: ACTION_DEFINITIONS["dismiss_for_collective"][:params_string], description: ACTION_DEFINITIONS["dismiss_for_collective"][:description] },
      ],
    },
    "/search" => {
      controller_actions: ["search#index"],
      actions: [
        { name: "search", params_string: ACTION_DEFINITIONS["search"][:params_string], description: ACTION_DEFINITIONS["search"][:description] },
      ],
    },
    "/collectives/:collective_handle/settings/webhooks" => {
      controller_actions: ["webhooks#index"],
      actions: [],
    },
    "/collectives/:collective_handle/settings/webhooks/new" => {
      controller_actions: ["webhooks#new"],
      actions: [
        { name: "create_webhook", params_string: ACTION_DEFINITIONS["create_webhook"][:params_string], description: ACTION_DEFINITIONS["create_webhook"][:description] },
      ],
    },
    "/collectives/:collective_handle/settings/webhooks/:id" => {
      controller_actions: ["webhooks#show"],
      actions: [
        { name: "update_webhook", params_string: ACTION_DEFINITIONS["update_webhook"][:params_string], description: ACTION_DEFINITIONS["update_webhook"][:description] },
        { name: "delete_webhook", params_string: ACTION_DEFINITIONS["delete_webhook"][:params_string], description: ACTION_DEFINITIONS["delete_webhook"][:description] },
        { name: "test_webhook", params_string: ACTION_DEFINITIONS["test_webhook"][:params_string], description: ACTION_DEFINITIONS["test_webhook"][:description] },
      ],
    },
    "/u/:handle/settings/webhooks" => {
      controller_actions: ["user_webhooks#index"],
      actions: [],
    },
    "/u/:handle/settings/webhooks/new" => {
      controller_actions: ["user_webhooks#new"],
      actions: [
        { name: "create_webhook", params_string: ACTION_DEFINITIONS["create_webhook"][:params_string], description: ACTION_DEFINITIONS["create_webhook"][:description] },
      ],
    },
    "/u/:handle/settings/webhooks/:id" => {
      controller_actions: ["user_webhooks#show"],
      actions: [
        { name: "delete_webhook", params_string: ACTION_DEFINITIONS["delete_webhook"][:params_string], description: ACTION_DEFINITIONS["delete_webhook"][:description] },
        { name: "test_webhook", params_string: ACTION_DEFINITIONS["test_webhook"][:params_string], description: ACTION_DEFINITIONS["test_webhook"][:description] },
      ],
    },
    "/u/:handle/settings/trustee-grants" => {
      controller_actions: ["trustee_grants#index"],
      actions: [],
    },
    "/u/:handle/settings/trustee-grants/new" => {
      controller_actions: ["trustee_grants#new"],
      actions: [
        { name: "create_trustee_grant", params_string: ACTION_DEFINITIONS["create_trustee_grant"][:params_string], description: ACTION_DEFINITIONS["create_trustee_grant"][:description] },
      ],
    },
    "/u/:handle/settings/trustee-grants/:grant_id" => {
      controller_actions: ["trustee_grants#show"],
      actions: [
        { name: "accept_trustee_grant", params_string: ACTION_DEFINITIONS["accept_trustee_grant"][:params_string], description: ACTION_DEFINITIONS["accept_trustee_grant"][:description] },
        { name: "decline_trustee_grant", params_string: ACTION_DEFINITIONS["decline_trustee_grant"][:params_string], description: ACTION_DEFINITIONS["decline_trustee_grant"][:description] },
        { name: "revoke_trustee_grant", params_string: ACTION_DEFINITIONS["revoke_trustee_grant"][:params_string], description: ACTION_DEFINITIONS["revoke_trustee_grant"][:description] },
        { name: "start_representation", params_string: ACTION_DEFINITIONS["start_representation"][:params_string], description: ACTION_DEFINITIONS["start_representation"][:description] },
        { name: "end_representation", params_string: ACTION_DEFINITIONS["end_representation"][:params_string], description: ACTION_DEFINITIONS["end_representation"][:description] },
      ],
    },
    "/ai-agents/:handle/automations" => {
      controller_actions: ["agent_automations#index"],
      actions: [],
    },
    "/ai-agents/:handle/automations/new" => {
      controller_actions: ["agent_automations#new"],
      actions: [
        { name: "create_automation_rule", params_string: ACTION_DEFINITIONS["create_automation_rule"][:params_string], description: ACTION_DEFINITIONS["create_automation_rule"][:description] },
      ],
    },
    "/ai-agents/:handle/automations/templates" => {
      controller_actions: ["agent_automations#templates"],
      actions: [],
    },
    "/ai-agents/:handle/automations/:automation_id" => {
      controller_actions: ["agent_automations#show"],
      actions: [
        { name: "update_automation_rule", params_string: ACTION_DEFINITIONS["update_automation_rule"][:params_string], description: ACTION_DEFINITIONS["update_automation_rule"][:description] },
        { name: "delete_automation_rule", params_string: ACTION_DEFINITIONS["delete_automation_rule"][:params_string], description: ACTION_DEFINITIONS["delete_automation_rule"][:description] },
        { name: "toggle_automation_rule", params_string: ACTION_DEFINITIONS["toggle_automation_rule"][:params_string], description: ACTION_DEFINITIONS["toggle_automation_rule"][:description] },
      ],
    },
    "/ai-agents/:handle/automations/:automation_id/edit" => {
      controller_actions: ["agent_automations#edit"],
      actions: [
        { name: "update_automation_rule", params_string: ACTION_DEFINITIONS["update_automation_rule"][:params_string], description: ACTION_DEFINITIONS["update_automation_rule"][:description] },
      ],
    },
    "/ai-agents/:handle/automations/:automation_id/runs" => {
      controller_actions: ["agent_automations#runs"],
      actions: [],
    },
  }

  # Reverse mapping from "controller#action" to route pattern.
  # Derived from @@actions_by_route at load time.
  @@controller_action_to_route = T.let(
    @@actions_by_route.each_with_object({}) do |(route_pattern, config), mapping|
      config[:controller_actions]&.each do |controller_action|
        mapping[controller_action] = route_pattern
      end
    end,
    T::Hash[String, String]
  )

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

  # Get routes and actions filtered by user authorization.
  # Only returns actions the user is authorized to see/execute.
  #
  # @param user [User, nil] The user to filter actions for
  # @param context [Hash] Additional context for authorization checks (collective, resource, etc.)
  # @return [Array<Hash>] Routes and their filtered actions, excluding routes with no visible actions
  sig do
    params(
      user: T.untyped,
      context: T::Hash[Symbol, T.untyped]
    ).returns(T::Array[T::Hash[Symbol, T.untyped]])
  end
  def self.routes_and_actions_for_user(user, context = {})
    @@routes_and_actions.map do |route_info|
      filtered_actions = route_info[:actions].select do |action|
        ActionAuthorization.authorized?(action[:name], user, context)
      end
      { route: route_info[:route], actions: filtered_actions }
    end.reject { |ri| ri[:actions].empty? }
  end

  sig { params(route: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.actions_for_route(route)
    # Normalize /workspace/ to /collectives/ — hash keys use /collectives/ but
    # both prefixes map to the same controllers and action definitions.
    normalized = route.sub(%r{^/workspace/}, "/collectives/")
    @@actions_by_route[normalized]
  end

  # Get the route pattern for a controller#action.
  # This is the single source of truth for mapping controller actions to route patterns.
  #
  # @param controller_action [String] The controller#action string (e.g., "notes#show")
  # @return [String, nil] The route pattern (e.g., "/collectives/:collective_handle/n/:note_id")
  sig { params(controller_action: String).returns(T.nilable(String)) }
  def self.route_pattern_for(controller_action)
    @@controller_action_to_route[controller_action]
  end
end
