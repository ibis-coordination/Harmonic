class AddActorTokenToDecisionAuditEntries < ActiveRecord::Migration[7.2]
  def change
    # actor_token: SHA256(decision_id || actor_id || actor_handle || actor_token_salt), included in the entry hash
    # actor_token_salt: 256-bit random value, NOT included in the entry hash; destroyed on PII scrub
    # Both nullable: NULL for system actions with no actor (e.g., beacon_drawn) and for entries whose actor was scrubbed
    add_column :decision_audit_entries, :actor_token, :string
    add_column :decision_audit_entries, :actor_token_salt, :string
  end
end
