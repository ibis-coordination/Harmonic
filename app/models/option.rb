# typed: true

class Option < ApplicationRecord
  extend T::Sig

  include Tracked
  include InvalidatesSearchIndex
  include HasRepresentationSessionAssociations
  include HasRepresentationSessionEvents

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :decision_participant
  belongs_to :decision

  has_many :votes, dependent: :destroy

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(decision).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_superagent_id
    self.superagent_id = T.must(decision).superagent_id if superagent_id.nil?
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

  private

  # Reindex the parent decision when options change (affects option_count)
  def search_index_items
    [decision].compact
  end
end
