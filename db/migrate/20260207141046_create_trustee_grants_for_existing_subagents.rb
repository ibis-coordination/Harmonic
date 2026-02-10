# typed: false

# Originally: Creates TrusteeGrants for existing subagent users that have a parent but don't already have a grant.
#
# This migration is now a no-op. The original implementation required creating synthetic "trustee" users
# which would immediately be cleaned up by the next migration (20260208054634). Instead, we skip this
# and backfill grants for subagents after the schema is in its final state.
#
# See migration 20260209000000_backfill_trustee_grants_for_subagents.rb for the actual backfill.
class CreateTrusteeGrantsForExistingSubagents < ActiveRecord::Migration[7.0]
  def up
    # No-op: backfill happens in a later migration after schema restructuring
  end

  def down
    # No-op
  end
end
