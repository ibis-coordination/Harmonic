# typed: true

class CommitmentParticipant < ApplicationRecord
  extend T::Sig

  include InvalidatesSearchIndex

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :commitment
  belongs_to :user, optional: true

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(commitment).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_superagent_id
    self.superagent_id = T.must(commitment).superagent_id if superagent_id.nil?
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      id: id,
      commitment_id: commitment_id,
      user_id: user_id,
      committed_at: committed_at,
    }
  end

  sig { returns(T::Boolean) }
  def authenticated?
    # If there is a user association, then we know the participant is authenticated
    user.present?
  end

  sig { returns(T::Boolean) }
  def has_dependent_resources?
    false
  end

  sig { returns(T::Boolean) }
  def committed?
    committed_at.present?
  end

  sig { returns(T::Boolean) }
  def committed
    committed?
  end

  sig { params(value: T.any(String, T::Boolean)).void }
  def committed=(value)
    if value == '1' || value == 'true' || value == true
      self.committed_at = T.cast(Time.current, ActiveSupport::TimeWithZone) unless committed?
    elsif value == '0' || value == 'false' || value == false
      self.committed_at = nil
    else
      raise 'Invalid value for committed'
    end
  end

  private

  # Reindex the parent commitment when participants change (affects participant_count)
  def search_index_items
    [commitment].compact
  end
end
