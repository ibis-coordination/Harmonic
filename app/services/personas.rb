# typed: strict
# frozen_string_literal: true

# Registry of the built-in agent personas — the single place a persona's
# identity facts live. Each entry pairs:
#
#   system_role         — also the mention tag (@cadence) and the handle prefix
#                         (cadence-<collective handle>); the User#system_role value.
#   name                — display name.
#   capability_role     — the grantable CollectiveMember role the persona holds
#                         while active.
#   default_model_env   — env var naming the default LLM model for newly
#                         seeded agents of this persona.
#   default_automations — the AutomationRule defaults seeded on first activation.
#
# The triad divides attention: melody focuses on DOING — making sure good
# things happen (expert in Harmonic's features and controls), counterpoint
# on VERIFYING — making sure bad things don't (expert in Harmonic's rules
# and boundaries), cadence on LEARNING — making sure the collective learns
# from whatever happens (expert in Harmonic's information architecture).
# Each persona's character lives in its prompt, read from
# app/services/personas/prompts/<system_role>.md.
#
# Together the three are known as Trio: every active persona also holds the
# shared ENSEMBLE_ROLE, so a @trio mention reaches all enabled built-in
# agents at once (see ReservedHandles and MentionParser).
#
# The identity constants elsewhere (User::SYSTEM_ROLES,
# ReservedHandles::AGENT_ROLES, HasRoles.persona_roles) stay literal for
# load-order simplicity; PersonasTest pins them to this registry so a new
# persona can't be half-added.
module Personas
  extend T::Sig

  # The ensemble: the collective noun for the three personas, and the shared
  # role that makes @trio reach all of them. Activator-managed, like the
  # persona roles — granted on activation, removed on deactivation, never
  # grantable through the role endpoints.
  ENSEMBLE_NAME = "Trio"
  ENSEMBLE_ROLE = "trio"

  class Definition < T::Struct
    extend T::Sig

    const :system_role, String
    const :name, String
    const :capability_role, String
    const :default_model_env, String
    const :default_automations, T::Array[T::Hash[Symbol, T.untyped]]

    # Read fresh on every call so prompt edits show up on the next render
    # without a Rails reload; the read cost is negligible. Resolved
    # dynamically via User#effective_identity_prompt — never snapshotted
    # into agent_configuration, so edits go live immediately for every
    # instance of the persona across every collective.
    sig { returns(String) }
    def prompt
      File.read(Rails.root.join("app/services/personas/prompts/#{system_role}.md"))
    end

    # Default LLM model for newly seeded agents of this persona. Resolved
    # from the env var so deployments can switch models without a code
    # change; must be gateway-resolvable on billing tenants. Operators can
    # override per-agent later via the agent settings page — the seeder's
    # refresh path does not overwrite existing values.
    sig { returns(T.nilable(String)) }
    def default_model
      ENV[default_model_env].presence
    end
  end

  MELODY = T.let(
    Definition.new(
      system_role: "melody",
      name: "Melody",
      capability_role: "automator",
      default_model_env: "MELODY_DEFAULT_MODEL",
      default_automations: [
        {
          name: "Respond to mentions and replies",
          description: "When @melody is mentioned, or when someone replies to a comment Melody wrote, navigate and respond.",
          event_types: ["note.created", "comment.created"],
          mention_filter: "self_or_reply",
          max_steps: 20,
          task: <<~TASK,
            You were mentioned (or replied to) by {{event.actor.name}} in {{subject.path}}.
            Navigate there and read the context — including the parent thread if
            this is a reply — then respond at the level the moment calls for: a
            comment if you have something to add, or a read confirmation if not.
          TASK
        },
      ],
    ),
    Definition
  )

  COUNTERPOINT = T.let(
    Definition.new(
      system_role: "counterpoint",
      name: "Counterpoint",
      capability_role: "moderator",
      default_model_env: "COUNTERPOINT_DEFAULT_MODEL",
      default_automations: [
        {
          name: "Respond to mentions and replies",
          description: "When @counterpoint is mentioned, or when someone replies to a comment Counterpoint wrote, navigate and respond.",
          event_types: ["note.created", "comment.created"],
          mention_filter: "self_or_reply",
          max_steps: 20,
          task: <<~TASK,
            You were mentioned (or replied to) by {{event.actor.name}} in {{subject.path}}.
            Navigate there and read the context — including the parent thread if
            this is a reply — then respond at the level the moment calls for: a
            comment if you have something to add, or a read confirmation if not.
          TASK
        },
      ],
    ),
    Definition
  )

  CADENCE = T.let(
    Definition.new(
      system_role: "cadence",
      name: "Cadence",
      capability_role: "summarizer",
      default_model_env: "CADENCE_DEFAULT_MODEL",
      default_automations: [
        {
          name: "Respond to mentions and replies",
          description: "When @cadence is mentioned, or when someone replies to a comment Cadence wrote, navigate and respond.",
          event_types: ["note.created", "comment.created"],
          mention_filter: "self_or_reply",
          max_steps: 20,
          task: <<~TASK,
            You were mentioned (or replied to) by {{event.actor.name}} in {{subject.path}}.
            Navigate there and read the context — including the parent thread if
            this is a reply — then respond at the level the moment calls for: a
            comment if you have something to add, or a read confirmation if not.
          TASK
        },
      ],
    ),
    Definition
  )

  ALL = T.let([MELODY, COUNTERPOINT, CADENCE].freeze, T::Array[Definition])

  sig { returns(T::Array[Definition]) }
  def self.all
    ALL
  end

  sig { returns(T::Array[String]) }
  def self.system_roles
    ALL.map(&:system_role)
  end

  sig { params(system_role: T.nilable(String)).returns(T.nilable(Definition)) }
  def self.fetch(system_role)
    ALL.find { |persona| persona.system_role == system_role }
  end
end
