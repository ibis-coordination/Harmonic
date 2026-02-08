# typed: true

class CreateRepresentationSessionEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :representation_session_events, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :superagent, type: :uuid, foreign_key: true # NULL for user representation
      t.references :representation_session, type: :uuid, null: false, foreign_key: true, index: { name: "idx_rep_events_session_id" }

      # Action tracking (using ActionsHelper naming)
      t.string :action_name, null: false # e.g., "create_note", "confirm_read", "vote"

      # The record this event is about
      t.string :resource_type, null: false
      t.uuid :resource_id, null: false

      # Parent for context/navigation (nullable for top-level creates)
      t.string :context_resource_type
      t.uuid :context_resource_id

      # Which studio the resource belongs to (may differ from session's superagent)
      t.references :resource_superagent, type: :uuid, null: false, foreign_key: { to_table: :superagents }, index: { name: "idx_rep_events_resource_superagent" }

      # For grouping bulk actions (all events from same HTTP request)
      t.string :request_id

      t.timestamps
    end

    # Index for "was this resource created during representation?"
    # Includes tenant_id first for multi-tenant query efficiency
    add_index :representation_session_events,
              [:tenant_id, :resource_type, :resource_id, :action_name],
              name: "idx_rep_events_resource_action"

    # Index for "all events for this context resource" (e.g., all votes on a decision)
    add_index :representation_session_events,
              [:tenant_id, :context_resource_type, :context_resource_id],
              name: "idx_rep_events_context"

    # Index for activity log display (session timeline)
    add_index :representation_session_events,
              [:tenant_id, :representation_session_id, :created_at],
              name: "idx_rep_events_session_timeline"

    # Index for grouping by request
    add_index :representation_session_events,
              [:tenant_id, :request_id],
              name: "idx_rep_events_request"
  end
end
