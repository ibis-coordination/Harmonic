# typed: true

# Concern for models that can be created during a representation session.
# Provides access to the RepresentationSession and representative_user
# for content created while someone was acting on behalf of another user.
#
# Display patterns:
# - Subagent content: "Alice (managed by Bob)" - Alice is subagent, Bob is parent
# - Representation content: "Alice on behalf of Bob" - Alice is representative, Bob is created_by
module HasRepresentationSessionEvents
  extend ActiveSupport::Concern
  extend T::Sig

  included do
    T.unsafe(self).has_many :representation_session_events,
                            as: :resource,
                            class_name: "RepresentationSessionEvent",
                            dependent: :destroy
  end

  # Returns the action name used when creating this resource type.
  # Override in subclasses if needed (e.g., Note uses "add_comment" when is_comment?)
  sig { returns(String) }
  def creation_action_name
    "create_#{T.unsafe(self).class.name.underscore}"
  end

  # Returns the event for when this resource was created during representation, if any
  sig { returns(T.nilable(RepresentationSessionEvent)) }
  def creation_representation_event
    RepresentationSessionEvent.creation_event_for(self, creation_action_name)
  end

  # Returns the RepresentationSession during which this content was created, if any
  sig { returns(T.nilable(RepresentationSession)) }
  def creation_representation_session
    creation_representation_event&.representation_session
  end

  # Returns the user who performed the creation action (the representative)
  sig { returns(T.nilable(User)) }
  def representative_user
    creation_representation_session&.representative_user
  end

  # Returns true if this content was created during a representation session
  sig { returns(T::Boolean) }
  def created_via_representation?
    creation_representation_event.present?
  end
end
