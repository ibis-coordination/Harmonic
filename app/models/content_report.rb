# typed: false

class ContentReport < ApplicationRecord
  REASONS = %w[harassment spam inappropriate misinformation other].freeze
  STATUSES = %w[pending reviewed dismissed actioned].freeze

  belongs_to :tenant
  belongs_to :reporter, class_name: "User"
  belongs_to :reportable, polymorphic: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :reason, inclusion: { in: REASONS }
  validates :status, inclusion: { in: STATUSES }
  validates :reporter_id, uniqueness: { scope: [:reportable_type, :reportable_id, :tenant_id] }
  validate :cannot_report_own_content

  scope :pending, -> { where(status: "pending") }

  def review!(admin:, status:, notes: nil)
    update!(
      reviewed_by: admin,
      status: status,
      admin_notes: notes,
      reviewed_at: Time.current,
    )
  end

  private

  def cannot_report_own_content
    return unless reportable.present? && reporter.present?

    if reportable.respond_to?(:created_by_id) && reportable.created_by_id == reporter_id
      errors.add(:reporter_id, "cannot report your own content")
    end
  end
end
