# typed: true

class Option < ApplicationRecord
  extend T::Sig

  include Tracked
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :decision_participant
  belongs_to :decision

  has_many :approvals, dependent: :destroy

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(decision).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_studio_id
    self.studio_id = T.must(decision).studio_id if studio_id.nil?
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      id: id,
      random_id: random_id,
      title: title,
      description: description,
      decision_id: decision_id,
      decision_participant_id: decision_participant_id,
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
