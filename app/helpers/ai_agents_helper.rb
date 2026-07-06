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

  # Models a user can pick for an internal agent. On a tenant that bills usage
  # through the gateway, the rate card is the source of truth for what's
  # available (litellm_config isn't consulted in gateway mode) — so we offer
  # exactly the priced models, which keeps the selector and the price table in
  # sync. Off billing (or if the catalog can't be reached), fall back to the
  # litellm_config list so the form still works.
  def selectable_models
    if @current_tenant&.feature_enabled?("stripe_billing")
      catalog = GatewayModelCatalog.prices
      return catalog.keys.sort if catalog.any?
    end

    available_llm_models
  end

  # Per-model prices for display next to the selector — [{ name:, input:,
  # output: }], one row per model the rate card prices, sorted to match
  # selectable_models. Answers "how much will this model cost me?". Empty when
  # the catalog is unavailable (Stripe error or not configured), so the view
  # shows nothing rather than breaking.
  def model_pricing_rows
    GatewayModelCatalog.prices.sort_by { |name, _rate| name }.map do |name, rate|
      { name: name, input: rate[:input_per_million], output: rate[:output_per_million] }
    end
  end
end
