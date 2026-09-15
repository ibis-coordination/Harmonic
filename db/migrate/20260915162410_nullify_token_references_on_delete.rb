# typed: true

# CleanupExpiredTokensJob hard-deletes tokens 30 days past expiry/soft-delete,
# but three foreign keys referencing api_tokens had no ON DELETE action, so a
# single referenced token aborted the whole delete_all batch — the job failed
# on every run once the first bridge-redeemed token aged out (Sentry
# RUBY-RAILS-1A, failing daily since 2026-08-24), and no tokens were cleaned
# at all.
#
# All three referencing columns are already `optional: true` in their models,
# and mcp_tool_call_logs.api_token_id set the precedent: a historical record
# outlives its token, keeping the row with a nullified reference.
class NullifyTokenReferencesOnDelete < ActiveRecord::Migration[7.2]
  def up
    swap_fk :harmonic_bridge_setups, column: :api_token_id, on_delete: :nullify
    swap_fk :harmonic_bridge_setups, column: :llm_api_token_id, on_delete: :nullify
    swap_fk :llm_usage_records, column: :api_token_id, on_delete: :nullify
  end

  def down
    swap_fk :harmonic_bridge_setups, column: :api_token_id, on_delete: nil
    swap_fk :harmonic_bridge_setups, column: :llm_api_token_id, on_delete: nil
    swap_fk :llm_usage_records, column: :api_token_id, on_delete: nil
  end

  private

  def swap_fk(table, column:, on_delete:)
    remove_foreign_key table, :api_tokens, column: column
    if on_delete
      add_foreign_key table, :api_tokens, column: column, on_delete: on_delete
    else
      add_foreign_key table, :api_tokens, column: column
    end
  end
end
