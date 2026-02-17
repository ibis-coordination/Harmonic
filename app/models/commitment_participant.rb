# typed: true

class CommitmentParticipant < ApplicationRecord
  extend T::Sig

  include InvalidatesSearchIndex
  include TracksUserItemStatus
  include HasRepresentationSessionEvents

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :collective
  before_validation :set_collective_id
  belongs_to :commitment
  belongs_to :user

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(commitment).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_collective_id
    self.collective_id = T.must(commitment).collective_id if collective_id.nil?
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
    # User is required, so participant is always authenticated
    true
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

  # Track when a user commits to a commitment
  def user_item_status_updates
    return [] unless committed?

    [
      {
        tenant_id: tenant_id,
        user_id: user_id,
        item_type: "Commitment",
        item_id: commitment_id,
        is_participating: true,
        participated_at: committed_at,
      },
    ]
  end
end
