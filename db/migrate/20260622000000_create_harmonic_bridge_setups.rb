class CreateHarmonicBridgeSetups < ActiveRecord::Migration[7.2]
  def change
    create_table :harmonic_bridge_setups, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :ai_agent_user, null: false, foreign_key: { to_table: :users }, type: :uuid, index: false
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }, type: :uuid, index: false
      # Nullable until each lifecycle step writes them:
      # - api_token + automation_rule + redeemed_at: written by GET. The
      #   AutomationRule is created here (with no URL, disabled) so its
      #   auto-generated webhook_secret can be returned to the bridge
      #   immediately, in the usual way.
      # - webhook_registered_at: written by POST when the rule is updated
      #   with the URL, enabled, and verified.
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
