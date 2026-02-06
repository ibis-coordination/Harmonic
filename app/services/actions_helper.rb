# typed: true

# ActionsHelper is the single source of truth for all action definitions.
# Controllers should use this helper to get action descriptions and parameters
# rather than duplicating definitions in describe_* methods.
class ActionsHelper
  extend T::Sig

  # Authorization for actions restricted to "person" user types only.
  # Subagents and trustees cannot create other subagents or API tokens.
  PERSON_ONLY_AUTHORIZATION = T.let(
    lambda { |user, context|
      return false unless user
      return false unless user.user_type == "person"

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
  # - Studio webhooks require superagent_admin
  # - User webhooks require self or representative access
  # - For listing (no context), allows authenticated users to see the action
  WEBHOOK_AUTHORIZATION = T.let(
    lambda { |user, context|
      return false unless user

      studio = context[:studio]
      target_user = context[:target_user]

      # If studio context exists and it's not the main superagent, check superagent_admin
      if studio && !studio.is_main_superagent?
        member = user.superagent_members.find_by(superagent_id: studio.id)
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

  # Full action definitions with parameter details.
  # Each action has: description, params_string (for display), params (detailed param info),
  # and authorization (who can see/execute this action).
  #
  # Authorization can be:
  # - A symbol (e.g., :authenticated, :studio_member, :app_admin)
  # - An array of symbols (OR logic - any authorization suffices)
  # - A Proc for custom logic: ->(user, context) { ... }
  #
  # Actions without authorization are denied by default (fail-closed).
  #
  # @see ActionAuthorization for the authorization checker
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
      authorization: :authenticated,
    },
    "join_studio" => {
      description: "Join the studio",
      params_string: "()",
      params: [
        { name: "code", type: "string", required: false, description: "Invite code (optional for scenes)" },
      ],
      authorization: :authenticated,
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
      authorization: :superagent_admin,
    },
    "add_subagent_to_studio" => {
      description: "Add one of your subagents to this studio",
      params_string: "(subagent_id)",
      params: [
        { name: "subagent_id", type: "integer", description: "ID of the subagent to add" },
      ],
      authorization: :superagent_admin,
    },
    "remove_subagent_from_studio" => {
      description: "Remove a subagent from this studio",
      params_string: "(subagent_id)",
      params: [
        { name: "subagent_id", type: "integer", description: "ID of the subagent to remove" },
      ],
      authorization: :superagent_admin,
    },
    "send_heartbeat" => {
      description: "Send a heartbeat to confirm your presence in the studio for this cycle",
      params_string: "()",
      params: [],
      authorization: :superagent_member,
    },

    # Note actions
    "create_note" => {
      description: "Create a new note",
      params_string: "(text)",
      params: [
        { name: "text", type: "string", description: "The text of the note" },
      ],
      authorization: :superagent_member,
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
      authorization: :superagent_member,
    },
    "pin_note" => {
      description: "Pin this note to the studio homepage",
      params_string: "()",
      params: [],
      authorization: :superagent_member,
    },
    "unpin_note" => {
      description: "Unpin this note from the studio homepage",
      params_string: "()",
      params: [],
      authorization: :superagent_member,
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
      authorization: :superagent_member,
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
      authorization: :superagent_member,
    },
    "vote" => {
      description: "Vote on one or more options",
      params_string: "(votes)",
      params: [
        { name: "votes", type: "array[object]", description: "Array of vote objects, each with: option_title (string), accept (boolean), prefer (boolean)" },
      ],
      authorization: :superagent_member,
    },
    "pin_decision" => {
      description: "Pin this decision to the studio homepage",
      params_string: "()",
      params: [],
      authorization: :superagent_member,
    },
    "unpin_decision" => {
      description: "Unpin this decision from the studio homepage",
      params_string: "()",
      params: [],
      authorization: :superagent_member,
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
      authorization: :superagent_member,
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
      authorization: :superagent_member,
    },
    "pin_commitment" => {
      description: "Pin this commitment to the studio homepage",
      params_string: "()",
      params: [],
      authorization: :superagent_member,
    },
    "unpin_commitment" => {
      description: "Unpin this commitment from the studio homepage",
      params_string: "()",
      params: [],
      authorization: :superagent_member,
    },

    # Comment action (shared across notes, decisions, commitments)
    "add_comment" => {
      description: "Add a comment",
      params_string: "(text)",
      params: [
        { name: "text", type: "string", description: "The text of the comment" },
      ],
      authorization: :superagent_member,
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
      authorization: :self_subagent,
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
      authorization: PERSON_ONLY_AUTHORIZATION,
    },
    "create_subagent" => {
      description: "Create a new subagent",
      params_string: "(name, identity_prompt, generate_token)",
      params: [
        { name: "name", type: "string", description: "The name of the subagent" },
        { name: "identity_prompt", type: "string", description: "A prompt shown to the agent on /whoami, providing context about their identity and purpose" },
        { name: "generate_token", type: "boolean", description: "Whether to generate an API token for the subagent" },
      ],
      authorization: PERSON_ONLY_AUTHORIZATION,
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
          description: "The search query. Supports operators: type:, status:, cycle:, creator:, studio:, etc.",
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
    "dismiss_for_studio" => {
      description: "Dismiss all notifications for a specific studio",
      params_string: "(studio_id)",
      params: [
        { name: "studio_id", type: "string", description: "The ID of the studio, or 'reminders' to dismiss due reminders" },
      ],
      authorization: :authenticated,
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
      authorization: :authenticated,
    },
    "delete_reminder" => {
      description: "Cancel a scheduled reminder before it triggers",
      params_string: "(id)",
      params: [
        { name: "id", type: "string", required: true, description: "The ID of the notification recipient to delete" },
      ],
      authorization: :authenticated,
    },

    # Webhook actions
    # Webhooks can be created for studios (requires superagent_admin) or users (requires self/representative).
    # Authorization is context-aware: checks studio context first, then falls back to user context.
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

    # Trustee Grant actions
    "create_trustee_grant" => {
      description: "Grant another user authority to act on your behalf",
      params_string: "(trusted_user_id, permissions, studio_scope_mode, studio_ids, expires_at, relationship_phrase)",
      params: [
        { name: "trusted_user_id", type: "string", required: true, description: "The ID of the user to grant authority to" },
        { name: "permissions", type: "array", required: true, description: "Array of capability names to grant (e.g., create_notes, vote, commit)" },
        { name: "studio_scope_mode", type: "string", description: 'Studio scope mode: "all" (default), "include", or "exclude"' },
        { name: "studio_ids", type: "array", description: "Array of studio IDs for include/exclude modes" },
        { name: "expires_at", type: "datetime", description: "When the trustee grant expires (optional)" },
        { name: "relationship_phrase", type: "string", description: 'Relationship description (optional, defaults to "{trusted_user} acts for {granting_user}")' },
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
  }.freeze

  # Route to actions mapping for actions index pages.
  # This is derived from ACTION_DEFINITIONS but organized by route.
  #
  # Each entry includes:
  # - controller_actions: Array of "controller#action" strings that map to this route pattern.
  #   Multiple controller#actions can map to the same route pattern (e.g., studios#show and studios#cycles).
  # - actions: Array of action definitions available at this route.
  #
  # The controller_actions mapping is the single source of truth for route pattern resolution.
  # MarkdownHelper.build_route_pattern_from_request uses this to look up route patterns.
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
    "/studios" => {
      controller_actions: ["studios#index"],
      actions: [],
    },
    "/studios/new" => {
      controller_actions: ["studios#new"],
      actions: [
        { name: "create_studio", params_string: ACTION_DEFINITIONS["create_studio"][:params_string], description: ACTION_DEFINITIONS["create_studio"][:description] },
      ],
    },
    "/studios/:studio_handle" => {
      controller_actions: ["pulse#show"],
      actions: [],
      conditional_actions: [
        {
          name: "send_heartbeat",
          condition: ->(context) {
            superagent = context[:superagent]
            current_heartbeat = context[:current_heartbeat]
            superagent && !superagent.is_main_superagent? && current_heartbeat.nil?
          },
        },
      ],
    },
    "/studios/:studio_handle/actions" => {
      controller_actions: ["pulse#actions_index"],
      actions: [],
      conditional_actions: [
        {
          name: "send_heartbeat",
          condition: ->(context) {
            superagent = context[:superagent]
            current_heartbeat = context[:current_heartbeat]
            superagent && !superagent.is_main_superagent? && current_heartbeat.nil?
          },
        },
      ],
    },
    "/studios/:studio_handle/join" => {
      controller_actions: ["studios#join"],
      actions: [
        { name: "join_studio", params_string: ACTION_DEFINITIONS["join_studio"][:params_string], description: ACTION_DEFINITIONS["join_studio"][:description] },
      ],
    },
    "/studios/:studio_handle/settings" => {
      controller_actions: ["studios#settings"],
      actions: [
        { name: "update_studio_settings", params_string: ACTION_DEFINITIONS["update_studio_settings"][:params_string], description: ACTION_DEFINITIONS["update_studio_settings"][:description] },
        { name: "add_subagent_to_studio", params_string: ACTION_DEFINITIONS["add_subagent_to_studio"][:params_string], description: ACTION_DEFINITIONS["add_subagent_to_studio"][:description] },
        { name: "remove_subagent_from_studio", params_string: ACTION_DEFINITIONS["remove_subagent_from_studio"][:params_string], description: ACTION_DEFINITIONS["remove_subagent_from_studio"][:description] },
      ],
    },
    "/studios/:studio_handle/cycles" => {
      controller_actions: ["cycles#index"],
      actions: [],
      conditional_actions: [
        {
          name: "send_heartbeat",
          condition: ->(context) {
            superagent = context[:superagent]
            current_heartbeat = context[:current_heartbeat]
            superagent && !superagent.is_main_superagent? && current_heartbeat.nil?
          },
        },
      ],
    },
    "/studios/:studio_handle/backlinks" => {
      controller_actions: ["studios#backlinks"],
      actions: [],
    },
    "/studios/:studio_handle/members" => {
      controller_actions: ["studios#members"],
      actions: [],
    },
    "/studios/:studio_handle/note" => {
      controller_actions: ["notes#new"],
      actions: [
        { name: "create_note", params_string: ACTION_DEFINITIONS["create_note"][:params_string], description: ACTION_DEFINITIONS["create_note"][:description] },
      ],
    },
    "/studios/:studio_handle/n/:note_id" => {
      controller_actions: ["notes#show"],
      actions: [
        { name: "confirm_read", params_string: ACTION_DEFINITIONS["confirm_read"][:params_string], description: "Confirm that you have read the note" },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: "Add a comment to this note" },
      ],
    },
    "/studios/:studio_handle/n/:note_id/attachments/:attachment_id" => {
      controller_actions: ["attachments#show"],
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/studios/:studio_handle/n/:note_id/edit" => {
      controller_actions: ["notes#edit"],
      actions: [
        { name: "update_note", params_string: ACTION_DEFINITIONS["update_note"][:params_string], description: "Update the note" },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: "Add a file attachment to this note" },
      ],
    },
    "/studios/:studio_handle/n/:note_id/settings" => {
      controller_actions: ["notes#settings"],
      actions: [],
    },
    "/studios/:studio_handle/decide" => {
      controller_actions: ["decisions#new"],
      actions: [
        { name: "create_decision", params_string: ACTION_DEFINITIONS["create_decision"][:params_string], description: ACTION_DEFINITIONS["create_decision"][:description] },
      ],
    },
    "/studios/:studio_handle/d/:decision_id" => {
      controller_actions: ["decisions#show"],
      actions: [
        { name: "add_options", params_string: ACTION_DEFINITIONS["add_options"][:params_string], description: ACTION_DEFINITIONS["add_options"][:description] },
        { name: "vote", params_string: ACTION_DEFINITIONS["vote"][:params_string], description: ACTION_DEFINITIONS["vote"][:description] },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: "Add a comment to this decision" },
      ],
    },
    "/studios/:studio_handle/d/:decision_id/attachments/:attachment_id" => {
      controller_actions: ["attachments#show"],
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/studios/:studio_handle/d/:decision_id/settings" => {
      controller_actions: ["decisions#settings"],
      actions: [
        { name: "update_decision_settings", params_string: ACTION_DEFINITIONS["update_decision_settings"][:params_string], description: ACTION_DEFINITIONS["update_decision_settings"][:description] },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: "Add a file attachment to this decision" },
      ],
    },
    "/studios/:studio_handle/commit" => {
      controller_actions: ["commitments#new"],
      actions: [
        { name: "create_commitment", params_string: ACTION_DEFINITIONS["create_commitment"][:params_string], description: ACTION_DEFINITIONS["create_commitment"][:description] },
      ],
    },
    "/studios/:studio_handle/c/:commitment_id" => {
      controller_actions: ["commitments#show"],
      actions: [
        { name: "join_commitment", params_string: ACTION_DEFINITIONS["join_commitment"][:params_string], description: ACTION_DEFINITIONS["join_commitment"][:description] },
        { name: "add_comment", params_string: ACTION_DEFINITIONS["add_comment"][:params_string], description: "Add a comment to this commitment" },
      ],
    },
    "/studios/:studio_handle/c/:commitment_id/attachments/:attachment_id" => {
      controller_actions: ["attachments#show"],
      actions: [
        { name: "remove_attachment", params_string: ACTION_DEFINITIONS["remove_attachment"][:params_string], description: ACTION_DEFINITIONS["remove_attachment"][:description] },
      ],
    },
    "/studios/:studio_handle/c/:commitment_id/settings" => {
      controller_actions: ["commitments#settings"],
      actions: [
        { name: "update_commitment_settings", params_string: ACTION_DEFINITIONS["update_commitment_settings"][:params_string], description: ACTION_DEFINITIONS["update_commitment_settings"][:description] },
        { name: "add_attachment", params_string: ACTION_DEFINITIONS["add_attachment"][:params_string], description: "Add a file attachment to this commitment" },
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
    "/u/:handle/settings/subagents/new" => {
      controller_actions: ["subagents#new"],
      actions: [
        { name: "create_subagent", params_string: ACTION_DEFINITIONS["create_subagent"][:params_string], description: ACTION_DEFINITIONS["create_subagent"][:description] },
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
        { name: "dismiss_for_studio", params_string: ACTION_DEFINITIONS["dismiss_for_studio"][:params_string], description: ACTION_DEFINITIONS["dismiss_for_studio"][:description] },
        { name: "create_reminder", params_string: ACTION_DEFINITIONS["create_reminder"][:params_string], description: ACTION_DEFINITIONS["create_reminder"][:description] },
        { name: "delete_reminder", params_string: ACTION_DEFINITIONS["delete_reminder"][:params_string], description: ACTION_DEFINITIONS["delete_reminder"][:description] },
      ],
    },
    "/search" => {
      controller_actions: ["search#index"],
      actions: [
        { name: "search", params_string: ACTION_DEFINITIONS["search"][:params_string], description: ACTION_DEFINITIONS["search"][:description] },
      ],
    },
    "/studios/:studio_handle/settings/webhooks" => {
      controller_actions: ["webhooks#index"],
      actions: [],
    },
    "/studios/:studio_handle/settings/webhooks/new" => {
      controller_actions: ["webhooks#new"],
      actions: [
        { name: "create_webhook", params_string: ACTION_DEFINITIONS["create_webhook"][:params_string], description: ACTION_DEFINITIONS["create_webhook"][:description] },
      ],
    },
    "/studios/:studio_handle/settings/webhooks/:id" => {
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
      actions: [],
      # Actions are dynamically computed based on grant state - see TrusteeGrantsController#actions_index_show
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
  # @param context [Hash] Additional context for authorization checks (studio, resource, etc.)
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
    @@actions_by_route[route]
  end

  # Get the route pattern for a controller#action.
  # This is the single source of truth for mapping controller actions to route patterns.
  #
  # @param controller_action [String] The controller#action string (e.g., "notes#show")
  # @return [String, nil] The route pattern (e.g., "/studios/:studio_handle/n/:note_id")
  sig { params(controller_action: String).returns(T.nilable(String)) }
  def self.route_pattern_for(controller_action)
    @@controller_action_to_route[controller_action]
  end
end
