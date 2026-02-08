# typed: false

# This migration simplifies TrusteeGrant by:
# 1. Collecting data about synthetic trustee users and their mappings
# 2. Re-attributing content from synthetic trustee users to granting_users
# 3. Removing trustee_user_id from RepresentationSession
# 4. Renaming trusted_user_id to trustee_user_id (the actual person becomes "the trustee")
# 5. Deleting orphaned synthetic trustee users
#
# After this migration:
# - granting_user = the user who grants authority (e.g., a subagent)
# - trustee_user = the user trusted to act on their behalf (e.g., the parent)
# - No synthetic "trustee" type users are created for TrusteeGrants
# - User type "trustee" only exists for Superagent trustees (studio representation)
class SimplifyTrusteeGrantRemoveSyntheticUsers < ActiveRecord::Migration[7.0]
  def up
    # Step 1: Find all synthetic trustee users (NOT superagent trustees)
    # These are users of type "trustee" that are not referenced by any Superagent
    superagent_trustee_ids = execute("SELECT trustee_user_id FROM superagents WHERE trustee_user_id IS NOT NULL").map { |r| r["trustee_user_id"] }

    synthetic_trustee_query = if superagent_trustee_ids.any?
      "SELECT id FROM users WHERE user_type = 'trustee' AND id NOT IN (#{superagent_trustee_ids.map { |id| "'#{id}'" }.join(", ")})"
    else
      "SELECT id FROM users WHERE user_type = 'trustee'"
    end

    synthetic_trustee_ids = execute(synthetic_trustee_query).map { |r| r["id"] }

    # Step 2: Build a mapping of synthetic trustee -> granting_user
    # IMPORTANT: Do this BEFORE changing the schema
    trustee_to_granting = {}
    synthetic_trustee_ids.each do |trustee_id|
      grant_result = execute("SELECT granting_user_id FROM trustee_grants WHERE trustee_user_id = '#{trustee_id}' LIMIT 1").first
      trustee_to_granting[trustee_id] = grant_result["granting_user_id"] if grant_result
    end

    # Step 3: Re-attribute content from synthetic trustees to granting_users
    trustee_to_granting.each do |trustee_id, granting_user_id|
      # Re-attribute content in tables with created_by_id
      %w[notes decisions commitments].each do |table_name|
        execute("UPDATE #{table_name} SET created_by_id = '#{granting_user_id}' WHERE created_by_id = '#{trustee_id}'")
      end

      # Re-attribute tables with user_id
      execute("UPDATE note_history_events SET user_id = '#{granting_user_id}' WHERE user_id = '#{trustee_id}'")
      execute("UPDATE heartbeats SET user_id = '#{granting_user_id}' WHERE user_id = '#{trustee_id}'")
    end

    # Step 4: Remove trustee_user_id from representation_sessions
    remove_column :representation_sessions, :trustee_user_id

    # Step 5: Swap columns on trustee_grants
    add_column :trustee_grants, :new_trustee_user_id, :uuid
    execute("UPDATE trustee_grants SET new_trustee_user_id = trusted_user_id")

    remove_index :trustee_grants, :trustee_user_id, if_exists: true
    remove_index :trustee_grants, :trusted_user_id, if_exists: true
    remove_column :trustee_grants, :trustee_user_id
    remove_column :trustee_grants, :trusted_user_id

    rename_column :trustee_grants, :new_trustee_user_id, :trustee_user_id
    change_column_null :trustee_grants, :trustee_user_id, false
    add_index :trustee_grants, :trustee_user_id
    add_foreign_key :trustee_grants, :users, column: :trustee_user_id

    # Step 6: Delete synthetic trustee users that we successfully re-attributed
    # Only delete users that were in the trustee_to_granting map (had a grant)
    # Orphaned synthetic trustees without grants are left alone to avoid data loss
    trustee_to_granting.keys.each do |trustee_id|
      execute("DELETE FROM tenant_users WHERE user_id = '#{trustee_id}'")
      execute("DELETE FROM users WHERE id = '#{trustee_id}'")
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Cannot reverse: synthetic trustee users were deleted"
  end
end
