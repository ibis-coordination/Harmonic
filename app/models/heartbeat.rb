# typed: false

class Heartbeat < ApplicationRecord
  include HasTruncatedId
  belongs_to :tenant
  belongs_to :studio
  belongs_to :user

  # TODO - activity log

  def self.where_in_cycle(cycle)
    self.where('created_at > ? and created_at < ?', cycle.start_date, cycle.end_date)
  end

  def self.current_for_studio(studio)
    self.where(studio: studio).where('expires_at > ?', Time.current)
  end

  def path_prefix
    'heartbeats'
  end
end