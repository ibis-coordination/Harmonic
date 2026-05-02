class AddDeadlineEventFiredAtToDecisionsAndCommitments < ActiveRecord::Migration[7.2]
  def change
    add_column :decisions, :deadline_event_fired_at, :datetime, null: true
    add_column :commitments, :deadline_event_fired_at, :datetime, null: true
  end
end
