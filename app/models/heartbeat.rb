# typed: true

class Heartbeat < ApplicationRecord
  extend T::Sig

  include HasTruncatedId
  include HasRepresentationSessionEvents

  belongs_to :tenant
  belongs_to :collective
  belongs_to :user

  # TODO - activity log

  sig { params(cycle: Cycle).returns(ActiveRecord::Relation) }
  def self.where_in_cycle(cycle)
    T.unsafe(self).where('created_at > ? and created_at < ?', cycle.start_date, cycle.end_date)
  end

  sig { params(collective: Collective).returns(ActiveRecord::Relation) }
  def self.current_for_collective(collective)
    T.unsafe(self).where(collective: collective).where('expires_at > ?', Time.current)
  end

  sig { returns(String) }
  def path_prefix
    'heartbeats'
  end
end