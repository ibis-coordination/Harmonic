# typed: true

class Heartbeat < ApplicationRecord
  extend T::Sig

  include HasTruncatedId
  belongs_to :tenant
  belongs_to :studio
  belongs_to :user

  # TODO - activity log

  sig { params(cycle: Cycle).returns(ActiveRecord::Relation) }
  def self.where_in_cycle(cycle)
    T.unsafe(self).where('created_at > ? and created_at < ?', cycle.start_date, cycle.end_date)
  end

  sig { params(studio: Studio).returns(ActiveRecord::Relation) }
  def self.current_for_studio(studio)
    T.unsafe(self).where(studio: studio).where('expires_at > ?', Time.current)
  end

  sig { returns(String) }
  def path_prefix
    'heartbeats'
  end
end