# typed: false

module AiAgentsHelper
  # Strip trailing JSON action block from LLM response for display.
  # The JSON action is shown in the subsequent step, so it's redundant here.
  #
  # Handles both fenced code blocks (```json...```) and raw JSON at the end.
  def strip_trailing_json_action(response)
    return "" if response.blank?

    response
      .to_s
      .sub(/```json\s*\{(?:(?!```).)*\}\s*```\s*\z/m, "")
      .sub(/\{"type":\s*"[^"]+",.*\}\s*\z/m, "")
      .strip
  end

  # True when `path` is a safe same-origin relative URL — a single leading
  # slash followed by a non-slash, e.g. "/collectives/foo/n/abc".
  #
  # Stored `display_path` values are computed server-side from `resource.path`
  # (see ApiHelper#compute_display_path) and are always of this shape, so a
  # scheme-bearing value ("javascript:...", "data:...") or a protocol-relative
  # host ("//evil.com") can't legitimately appear. Rendering the path as an
  # `href` only when this returns true converts that construction-time
  # invariant into an enforced one: if a scheme ever reaches the column via a
  # future regression, it renders as inert text instead of a clickable link.
  # HTML-escaping alone does NOT neutralize a `javascript:` href — the scheme
  # contains no metacharacters — so this gate is the actual guard.
  def safe_internal_path?(path)
    path.to_s.match?(%r{\A/(?!/)})
  end

  # Returns list of available LLM model names from litellm_config.yaml
  def available_llm_models
    config_path = Rails.root.join("config/litellm_config.yaml")
    return ["default"] unless File.exist?(config_path)

    config = YAML.load_file(config_path)
    model_list = config["model_list"] || []
    models = model_list.filter_map { |m| m["model_name"] }
    models.presence || ["default"]
  end

  # The gateway models offered for internal agents, configured per tenant on
  # the tenant-admin settings page (Tenant#enabled_gateway_models) — the rate
  # card differs across environments, so this can't be hardcoded. Until an admin
  # configures a set, fall back to the litellm_config list; the rate-card
  # intersection in offered_priced_models drops anything the gateway doesn't
  # price anyway.
  def offered_gateway_models
    configured = @current_tenant&.enabled_gateway_models
    configured.presence || available_llm_models
  end

  # Offered models the rate card actually prices, in the offering's order. The
  # single source both the selector and the price table draw from, so they can
  # never disagree. Empty off billing or when the catalog is unreachable.
  def offered_priced_models
    return [] unless @current_tenant&.feature_enabled?("stripe_billing")

    catalog = GatewayModelCatalog.prices
    return [] if catalog.empty?

    offered_gateway_models.select { |model| catalog.key?(model) }
  end

  # Models a user can pick for an internal agent. On a billing tenant, the
  # curated offering (priced by the rate card); otherwise the litellm_config
  # list, which is what LiteLLM routing can actually serve.
  def selectable_models
    priced = offered_priced_models
    priced.any? ? priced : available_llm_models
  end

  # Per-model prices for display next to the selector — [{ name:, input:,
  # output: }], one row per offered+priced model, in the same order as
  # selectable_models. Answers "how much will this model cost me?".
  def model_pricing_rows
    catalog = GatewayModelCatalog.prices
    offered_priced_models.map do |model|
      rate = catalog[model]
      { name: model, input: rate[:input_per_million], output: rate[:output_per_million] }
    end
  end
end
