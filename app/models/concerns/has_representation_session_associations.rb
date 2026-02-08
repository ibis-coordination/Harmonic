# typed: true

# Concern for models that can be created during a representation session.
# Provides access to the RepresentationSession and representative_user
# for content created while someone was acting on behalf of another user.
#
# Display patterns:
# - Subagent content: "Alice (managed by Bob)" - Alice is subagent, Bob is parent
# - Representation content: "Alice on behalf of Bob" - Alice is representative, Bob is created_by
module HasRepresentationSessionAssociations
  extend ActiveSupport::Concern
  extend T::Sig

  included do
    T.unsafe(self).has_one :representation_session_association,
                           as: :resource,
                           class_name: "RepresentationSessionAssociation",
                           dependent: :destroy
  end

  # Returns the RepresentationSession during which this content was created, if any
  sig { returns(T.nilable(RepresentationSession)) }
  def representation_session
    assoc = T.unsafe(self).representation_session_association
    assoc&.representation_session
  end

  # Returns the user who performed the action (the representative), if this content
  # was created during a representation session
  sig { returns(T.nilable(User)) }
  def representative_user
    representation_session&.representative_user
  end

  # Returns true if this content was created during a representation session
  sig { returns(T::Boolean) }
  def created_via_representation?
    T.unsafe(self).representation_session_association.present?
  end
end
