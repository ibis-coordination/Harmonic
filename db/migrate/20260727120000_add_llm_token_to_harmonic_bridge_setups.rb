# Opt-in third credential for the bridge handshake: when the human checks the
# box at setup creation, redeem! mints an llm_gateway-type ApiToken alongside
# the MCP token so Harmonic can be the external agent's LLM provider. The
# reference is nullable for the same lifecycle reason as api_token_id — and
# stays nil when the operator didn't opt in or the agent had no structural
# payer at redemption.
class AddLLMTokenToHarmonicBridgeSetups < ActiveRecord::Migration[7.2]
  def change
    add_column :harmonic_bridge_setups, :include_llm_token, :boolean, null: false, default: false
    add_reference :harmonic_bridge_setups, :llm_api_token, foreign_key: { to_table: :api_tokens }, type: :uuid
  end
end
