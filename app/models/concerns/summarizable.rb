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
    return false unless user.present?
    member = collective.collective_members.find_by(user: user)
    member.present? && member.can_summarize?
  end

  def is_summarizable?
    true
  end
end
