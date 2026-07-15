# typed: false

class AddStartingEventFiredAtToCommitments < ActiveRecord::Migration[7.2]
  def change
    add_column :commitments, :starting_soon_event_fired_at, :timestamp
    add_column :commitments, :starting_event_fired_at, :timestamp
  end
end
