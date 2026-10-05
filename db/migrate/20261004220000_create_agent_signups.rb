# typed: true

class CreateAgentSignups < ActiveRecord::Migration[7.2]
  def change
    create_table :agent_signups, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid, index: false
      # Nil when the named email matched no eligible member. Such a signup can
      # never be claimed; it exists so the agent-facing responses are the same
      # whether or not the email matched.
      t.references :principal_user, foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid, index: false
      # Written at claim and at pickup. A signup is a historical record that
      # outlives its agent and its token.
      t.references :ai_agent_user, foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid
      t.references :api_token, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :public_id, null: false
      t.string :poll_secret_digest, null: false
      t.string :pairing_code_digest, null: false
      t.integer :failed_pairing_attempts, null: false, default: 0
      t.string :proposed_name, null: false
      t.string :proposed_handle
      t.string :state, null: false, default: "pending"
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.datetime :redeemed_at
      t.timestamps
    end

    add_index :agent_signups, [:tenant_id, :public_id], unique: true
    add_index :agent_signups, [:tenant_id, :principal_user_id, :state]
    add_index :agent_signups, :expires_at
    add_check_constraint :agent_signups,
                         "state IN ('pending', 'claimed', 'redeemed', 'declined')",
                         name: "agent_signups_state_check"
  end
end
