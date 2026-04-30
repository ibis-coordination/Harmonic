# typed: false

module Statementable
  extend ActiveSupport::Concern

  included do
    has_one :statement, -> { where(subtype: "statement") },
            class_name: "Note",
            as: :statementable,
            dependent: :destroy
  end

  def can_write_statement?(user)
    # Default: creator can write the statement.
    # Override in including models for different permission logic
    # (e.g., executive decisions allow the designated decision maker).
    user.id == created_by_id
  end
end
