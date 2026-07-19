# typed: true

class AuthorComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      resource: T.any(Note, Decision, Commitment),
      verb: T.nilable(String),
      current_user: T.nilable(User),
      show_updated: T::Boolean
    ).void
  end
  def initialize(resource:, verb: nil, current_user: nil, show_updated: true)
    super()
    @resource = resource
    @verb = verb
    @current_user = current_user
    @show_updated = show_updated
  end

  sig { returns(T::Boolean) }
  def render?
    display_author.present?
  end

  private

  sig { returns(T.nilable(User)) }
  def author
    @resource.created_by
  end

  sig { returns(T.nilable(User)) }
  def representative
    @resource.respond_to?(:representative_user) ? @resource.representative_user : nil
  end

  sig { returns(T::Boolean) }
  def representation?
    !!(@resource.respond_to?(:created_via_representation?) &&
      @resource.created_via_representation? &&
      representative.present?)
  end

  sig { returns(T.nilable(User)) }
  def display_author
    representation? ? representative : author
  end

  # The agent's parent sees the link; for collective-principaled agents (the
  # personas, whose parent is the collective's identity user) the principal
  # collective's automation managers — active admins and automators — see it
  # instead. Mirrors the authorization on the run page itself
  # (AiAgentsController#find_ai_agent_for_run_views).
  sig { returns(T::Boolean) }
  def show_task_run_link?
    a = author
    return false unless a.present? && a.ai_agent? && @current_user.present?
    return true if a.parent == @current_user

    collective = a.principal_collective
    return false unless collective

    member = collective.collective_members.find_by(user: @current_user)
    !!member&.can_manage_automations?
  end

  sig { returns(T.nilable(AiAgentTaskRun)) }
  def task_run
    return nil unless show_task_run_link?

    AiAgentTaskRunResource.task_run_for(@resource)
  end

  sig { returns(T::Boolean) }
  def updated?
    @show_updated && @resource.updated_at > @resource.created_at + 1.minute
  end
end
