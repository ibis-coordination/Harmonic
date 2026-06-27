# typed: false

module Summarizable
  extend ActiveSupport::Concern

  included do
    has_one :summary, -> { where(subtype: "summary") },
            class_name: "Note",
            as: :summarizable,
            dependent: :destroy
  end

  def can_write_summary?(user)
    user.present?
  end

  def is_summarizable?
    true
  end
end
