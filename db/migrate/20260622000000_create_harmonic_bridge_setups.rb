class CreateHarmonicBridgeSetups < ActiveRecord::Migration[7.2]
  def change
    create_table :harmonic_bridge_setups, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :ai_agent_user, null: false, foreign_key: { to_table: :users }, type: :uuid, index: false
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }, type: :uuid, index: false
      # Nullable until completion — credentials are minted in the POST step,
      # not the GET. An abandoned redemption (GET with no follow-up POST)
      # leaves these columns null and leaks nothing.
      t.references :api_token, foreign_key: true, type: :uuid
      t.references :automation_rule, foreign_key: true, type: :uuid
      t.string :public_id, null: false
      t.datetime :expires_at, null: false
      t.datetime :redeemed_at
      t.datetime :webhook_registered_at
      # Default event types we tell the runner to subscribe to in the GET
      # response. The runner can override on the POST; this is a suggestion,
      # not a constraint (Harmonic only fires the small fixed set of agent-
      # facing notification events anyway).
      t.jsonb :events_recommended, null: false, default: []
      t.timestamps
    end

    add_index :harmonic_bridge_setups, [:tenant_id, :public_id], unique: true
    add_index :harmonic_bridge_setups, :expires_at
  end
end
