# typed: false

# Backfills TrusteeGrants for existing subagent users that have a parent but don't already have a grant.
# This runs after the schema restructuring (20260208054634) so we use the simplified schema:
# - granting_user_id: the subagent
# - trustee_user_id: the parent (the person trusted to act on behalf of the subagent)
class BackfillTrusteeGrantsForSubagents < ActiveRecord::Migration[7.0]
  def up
    # Find all subagent users with a parent that don't already have a TrusteeGrant
    subagents = execute(<<~SQL)
      SELECT u.id, u.parent_id
      FROM users u
      WHERE u.user_type = 'subagent'
        AND u.parent_id IS NOT NULL
        AND u.id NOT IN (SELECT granting_user_id FROM trustee_grants)
    SQL

    subagents.each do |subagent|
      subagent_id = subagent["id"]
      parent_id = subagent["parent_id"]

      # Get the tenant for this subagent via their tenant_user
      tenant_user = execute(<<~SQL).first
        SELECT tenant_id FROM tenant_users WHERE user_id = '#{subagent_id}' LIMIT 1
      SQL
      next unless tenant_user

      tenant_id = tenant_user["tenant_id"]

      all_permissions = {
        "create_note" => true,
        "update_note" => true,
        "create_decision" => true,
        "update_decision_settings" => true,
        "create_commitment" => true,
        "update_commitment_settings" => true,
        "vote" => true,
        "add_options" => true,
        "join_commitment" => true,
        "add_comment" => true,
        "pin_note" => true,
        "unpin_note" => true,
        "pin_decision" => true,
        "unpin_decision" => true,
        "pin_commitment" => true,
        "unpin_commitment" => true,
        "send_heartbeat" => true,
      }.to_json

      execute(<<~SQL)
        INSERT INTO trustee_grants (
          tenant_id,
          granting_user_id,
          trustee_user_id,
          accepted_at,
          permissions,
          studio_scope,
          created_at,
          updated_at
        )
        VALUES (
          '#{tenant_id}',
          '#{subagent_id}',
          '#{parent_id}',
          NOW(),
          '#{all_permissions}',
          '{"mode": "all"}',
          NOW(),
          NOW()
        )
      SQL
    end
  end

  def down
    # Delete TrusteeGrants created for subagent-parent relationships
    execute(<<~SQL)
      DELETE FROM trustee_grants
      WHERE granting_user_id IN (
        SELECT u.id FROM users u
        WHERE u.user_type = 'subagent'
          AND u.parent_id IS NOT NULL
          AND u.parent_id = trustee_grants.trustee_user_id
      )
    SQL
  end
end
