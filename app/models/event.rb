# typed: true

class Event < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :studio
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :subject, polymorphic: true, optional: true

  has_many :notifications, dependent: :destroy

  validates :event_type, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :of_type, ->(type) { where(event_type: type) }
  scope :for_subject, ->(subject) { where(subject_type: subject.class.name, subject_id: subject.id) }

  sig { returns(String) }
  def event_category
    T.must(T.unsafe(self).event_type).split(".").first
  end

  sig { returns(String) }
  def event_action
    T.must(T.unsafe(self).event_type).split(".").last
  end
end
