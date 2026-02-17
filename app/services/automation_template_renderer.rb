# typed: true

class AutomationTemplateRenderer
  extend T::Sig

  # Renders {{variable}} templates with event and subject context
  sig { params(template: String, context: T::Hash[String, T.untyped]).returns(String) }
  def self.render(template, context)
    new(template, context).render
  end

  sig { params(template: String, context: T::Hash[String, T.untyped]).void }
  def initialize(template, context)
    @template = template
    @context = context
  end

  sig { returns(String) }
  def render
    @template.gsub(/\{\{([^}]+)\}\}/) do |_match|
      match_data = Regexp.last_match(1)
      next "" if match_data.nil?

      path = match_data.strip
      value = resolve_path(path)
      sanitize_output(value)
    end
  end

  # Build context hash from an event
  sig { params(event: Event).returns(T::Hash[String, T.untyped]) }
  def self.context_from_event(event)
    context = {
      "event" => build_event_context(event),
      "subject" => build_subject_context(event.subject),
    }

    superagent = event.superagent
    context["studio"] = build_studio_context(superagent) if superagent

    context
  end

  # Build context hash from trigger_data (for webhook/schedule/manual triggers without events)
  sig { params(trigger_data: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def self.context_from_trigger_data(trigger_data)
    context = {}

    # Expose the webhook payload directly for template access
    # e.g., {{payload.event}}, {{payload.data.value}}
    if trigger_data["payload"].is_a?(Hash)
      context["payload"] = trigger_data["payload"]
    elsif trigger_data["payload"].is_a?(String)
      context["payload"] = { "raw" => trigger_data["payload"] }
    end

    # Expose manual trigger inputs for template access
    # e.g., {{inputs.message}}, {{inputs.count}}
    if trigger_data["inputs"].is_a?(Hash)
      context["inputs"] = trigger_data["inputs"]
    end

    # Expose webhook metadata
    # e.g., {{webhook.path}}, {{webhook.source_ip}}
    context["webhook"] = {
      "path" => trigger_data["webhook_path"],
      "received_at" => trigger_data["received_at"],
      "source_ip" => trigger_data["source_ip"],
    }

    context
  end

  sig { params(event: Event).returns(T::Hash[String, T.untyped]) }
  def self.build_event_context(event)
    actor = event.actor
    actor_context = if actor
                      {
                        "id" => actor.id,
                        "name" => actor.display_name,
                        "handle" => actor.tenant_user&.handle,
                      }
                    end

    {
      "type" => event.event_type,
      "actor" => actor_context,
      "metadata" => event.metadata || {},
      "created_at" => event.created_at.iso8601,
    }
  end

  sig { params(subject: T.untyped).returns(T::Hash[String, T.untyped]) }
  def self.build_subject_context(subject)
    return {} unless subject

    context = {
      "id" => subject.id,
      "type" => subject.class.name.underscore,
    }

    # Add common fields if available
    context["path"] = subject.path if subject.respond_to?(:path)
    context["title"] = extract_title(subject)
    context["text"] = extract_text(subject)
    context["created_by"] = build_user_context(subject.created_by) if subject.respond_to?(:created_by) && subject.created_by

    context
  end

  sig { params(superagent: Superagent).returns(T::Hash[String, T.untyped]) }
  def self.build_studio_context(superagent)
    {
      "id" => superagent.id,
      "handle" => superagent.handle,
      "name" => superagent.name,
      "path" => superagent.path,
    }
  end

  sig { params(user: User).returns(T::Hash[String, T.untyped]) }
  def self.build_user_context(user)
    {
      "id" => user.id,
      "name" => user.display_name,
      "handle" => user.tenant_user&.handle,
    }
  end

  sig { params(subject: T.untyped).returns(T.nilable(String)) }
  def self.extract_title(subject)
    if subject.respond_to?(:title)
      subject.title
    elsif subject.respond_to?(:question)
      subject.question
    elsif subject.respond_to?(:name)
      subject.name
    end
  end

  sig { params(subject: T.untyped).returns(T.nilable(String)) }
  def self.extract_text(subject)
    if subject.respond_to?(:text)
      subject.text
    elsif subject.respond_to?(:description)
      subject.description
    end
  end

  private

  sig { params(path: String).returns(T.nilable(T.any(String, Integer, Float, T::Boolean, T::Hash[String, T.untyped], T::Array[T.untyped]))) }
  def resolve_path(path)
    parts = path.split(".")
    resolve_path_recursive(@context, parts)
  end

  sig do
    params(
      current: T.nilable(T.any(String, Integer, Float, T::Boolean, T::Hash[String, T.untyped], T::Array[T.untyped])),
      remaining_parts: T::Array[String]
    ).returns(T.nilable(T.any(String, Integer, Float, T::Boolean, T::Hash[String, T.untyped], T::Array[T.untyped])))
  end
  def resolve_path_recursive(current, remaining_parts)
    return current if remaining_parts.empty?
    return nil unless current.is_a?(Hash)

    part = remaining_parts.first
    return nil if part.nil?

    next_value = current[part]
    resolve_path_recursive(next_value, remaining_parts.drop(1))
  end

  sig { params(value: T.untyped).returns(String) }
  def sanitize_output(value)
    return "" if value.nil?

    # JSON-encode complex types (Hash, Array) for clean output
    # Scalars (String, Integer, etc.) use to_s
    str = case value
          when Hash, Array
            value.to_json
          else
            value.to_s
          end

    # Sanitize HTML entities for safety
    ERB::Util.html_escape(str)
  end
end
