# typed: true

class AuthorComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      resource: T.any(Note, Decision, Commitment),
      verb: T.nilable(String),
      current_user: T.nilable(User),
    ).void
  end
  def initialize(resource:, verb: nil, current_user: nil)
    super()
    @resource = resource
    @verb = verb
    @current_user = current_user
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

  sig { returns(T::Boolean) }
  def show_task_run_link?
    a = author
    a.present? && a.ai_agent? && a.parent == @current_user
  end

  sig { returns(T.nilable(AiAgentTaskRun)) }
  def task_run
    return nil unless show_task_run_link?

    AiAgentTaskRunResource.task_run_for(@resource)
  end

  sig { returns(T::Boolean) }
  def updated?
    @resource.updated_at > @resource.created_at + 1.minute
  end
end
