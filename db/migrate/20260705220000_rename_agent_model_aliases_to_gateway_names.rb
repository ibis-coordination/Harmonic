# typed: false
# frozen_string_literal: true

# Model names are unified on the Stripe gateway's provider/model scheme —
# config/litellm_config.yaml now uses the same names, and
# StripeGatewayModelMapper no longer translates aliases. Rename the retired
# LiteLLM-only aliases stored in agent configurations so existing agents keep
# working.
class RenameAgentModelAliasesToGatewayNames < ActiveRecord::Migration[7.2]
  RENAMES = {
    "claude-sonnet-4" => "anthropic/claude-sonnet-4.6",
    "claude-haiku-4" => "anthropic/claude-haiku-4.5",
    "claude-opus-4" => "anthropic/claude-opus-4.7",
    "gpt-4o" => "openai/gpt-4o",
  }.freeze

  def up
    RENAMES.each do |from, to|
      update_model(from, to)
    end
  end

  def down
    RENAMES.each do |from, to|
      update_model(to, from)
    end
  end

  private

  def update_model(from, to)
    execute(<<~SQL.squish)
      UPDATE users
      SET agent_configuration = jsonb_set(agent_configuration, '{model}', #{quote("\"#{to}\"")}::jsonb)
      WHERE agent_configuration->>'model' = #{quote(from)}
    SQL
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
