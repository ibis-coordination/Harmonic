# typed: true

# Provides the instance variables and helpers that markdown templates expect.
#
# ViewContext mimics what controllers provide to views, enabling rendering outside
# of a controller context. It holds all the instance variables that templates
# access (e.g., @current_user, @note, @pinned_items) and provides a {#to_assigns}
# method to convert them to a hash for ActionView.
#
# Instance variables are grouped into categories:
# - **Core context**: Required by the layout (current_tenant, current_user, etc.)
# - **Cycle/heartbeat**: For studio activity tracking
# - **Resource-specific**: The current note, decision, or commitment being viewed
# - **Collections**: Lists like pinned_items, team members, cycles
#
# The {MarkdownUiService::ResourceLoader} populates these variables based on the route.
#
# @example Creating a ViewContext
#   context = MarkdownUiService::ViewContext.new(
#     tenant: tenant,
#     superagent: superagent,
#     user: user,
#     current_path: "/studios/team"
#   )
#   context.page_title = "Team Studio"
#   context.to_assigns  # => Hash for ActionView
#
# @see MarkdownUiService::ResourceLoader For how variables are populated
#
class MarkdownUiService
  class ViewContext
    extend T::Sig

    # Core context (required by layout)
    sig { returns(Tenant) }
    attr_accessor :current_tenant

    sig { returns(Superagent) }
    attr_accessor :current_superagent

    sig { returns(T.nilable(User)) }
    attr_accessor :current_user

    sig { returns(T.nilable(String)) }
    attr_accessor :current_path

    sig { returns(T.nilable(String)) }
    attr_accessor :page_title

    sig { returns(Integer) }
    attr_accessor :unread_notification_count

    # Cycle/heartbeat context
    sig { returns(T.nilable(Cycle)) }
    attr_accessor :current_cycle

    sig { returns(T.nilable(Heartbeat)) }
    attr_accessor :current_heartbeat

    # Resource-specific context
    sig { returns(T.nilable(Note)) }
    attr_accessor :note

    sig { returns(T.nilable(Decision)) }
    attr_accessor :decision

    sig { returns(T.nilable(Commitment)) }
    attr_accessor :commitment

    sig { returns(T.nilable(NoteReader)) }
    attr_accessor :note_reader

    sig { returns(T.nilable(DecisionParticipant)) }
    attr_accessor :decision_participant

    sig { returns(T.nilable(CommitmentParticipant)) }
    attr_accessor :commitment_participant

    # Studio context
    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    attr_accessor :pinned_items

    sig { returns(T::Array[User]) }
    attr_accessor :team

    sig { returns(T::Array[Cycle]) }
    attr_accessor :cycles

    # Notification context
    sig { returns(T::Array[NotificationRecipient]) }
    attr_accessor :notifications

    # Home page context
    sig { returns(T::Array[Superagent]) }
    attr_accessor :studios

    sig do
      params(
        tenant: Tenant,
        superagent: Superagent,
        user: T.nilable(User),
        current_path: T.nilable(String)
      ).void
    end
    def initialize(tenant:, superagent:, user:, current_path:)
      @current_tenant = tenant
      @current_superagent = superagent
      @current_user = user
      @current_path = current_path
      @page_title = T.let(nil, T.nilable(String))
      @unread_notification_count = T.let(0, Integer)

      # Cycle/heartbeat
      @current_cycle = T.let(nil, T.nilable(Cycle))
      @current_heartbeat = T.let(nil, T.nilable(Heartbeat))

      # Resources
      @note = T.let(nil, T.nilable(Note))
      @decision = T.let(nil, T.nilable(Decision))
      @commitment = T.let(nil, T.nilable(Commitment))
      @note_reader = T.let(nil, T.nilable(NoteReader))
      @decision_participant = T.let(nil, T.nilable(DecisionParticipant))
      @commitment_participant = T.let(nil, T.nilable(CommitmentParticipant))

      # Collections
      @pinned_items = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      @team = T.let([], T::Array[User])
      @cycles = T.let([], T::Array[Cycle])
      @notifications = T.let([], T::Array[NotificationRecipient])
      @studios = T.let([], T::Array[Superagent])

      # Load initial context
      load_initial_context
    end

    # Convert context to assigns hash for ActionView
    sig { returns(T::Hash[String, T.untyped]) }
    def to_assigns
      {
        # Layout variables (prefixed with @current_ or @)
        "current_tenant" => @current_tenant,
        "current_superagent" => @current_superagent,
        "current_user" => @current_user,
        "current_path" => @current_path,
        "page_title" => @page_title,
        "unread_notification_count" => @unread_notification_count,
        "current_cycle" => @current_cycle,
        "current_heartbeat" => @current_heartbeat,

        # Resource variables (templates use @note, @decision, etc.)
        "note" => @note,
        "decision" => @decision,
        "commitment" => @commitment,
        "note_reader" => @note_reader,
        "decision_participant" => @decision_participant,
        "commitment_participant" => @commitment_participant,

        # Collection variables
        "pinned_items" => @pinned_items,
        "team" => @team,
        "cycles" => @cycles,
        "notifications" => @notifications,
        "studios" => @studios,
      }
    end

    private

    sig { void }
    def load_initial_context
      # Load notification count
      if @current_user
        @unread_notification_count = NotificationService.unread_count_for(@current_user, tenant: @current_tenant)
      end

      # Load current cycle
      @current_cycle = @current_superagent.current_cycle

      # Load heartbeat if user is logged in and not on main superagent
      if @current_user && !@current_superagent.is_main_superagent? && @current_cycle
        @current_heartbeat = Heartbeat.where(
          tenant: @current_tenant,
          superagent: @current_superagent,
          user: @current_user
        ).where(
          "created_at > ? AND expires_at > ?",
          @current_cycle.start_date,
          Time.current
        ).first
      end
    end
  end
end
