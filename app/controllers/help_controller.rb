# typed: false

class HelpController < ApplicationController
  TOPICS = [
    "privacy", "collectives", "notes", "reminder_notes", "table_notes",
    "decisions", "executive_decisions", "lottery_decisions",
    "commitments", "calendar_events", "policies", "cycles", "search", "links", "lists",
    "agents", "trio", "automations", "api", "rest_api", "markdown_ui", "mcp", "notifications", "representation",
    "billing",
  ].freeze

  # Topics that are only available when a feature flag is enabled.
  # The hidden topic returns 404 and is omitted from the index — see app/views/help/index.md.erb.
  FEATURE_GATED_TOPICS = {
    "api" => "api",
    "rest_api" => "api",
    "mcp" => "api",
    "trio" => "trio",
    "billing" => "stripe_billing",
  }.freeze

  # Display name overrides for topics whose `titleize` is wrong.
  # Anything not in this map falls back to `topic.titleize`.
  TOPIC_DISPLAY_NAMES = {
    "api" => "API",
    "rest_api" => "REST API",
    "mcp" => "MCP",
    "markdown_ui" => "Markdown UI",
  }.freeze

  helper_method :help_topic_available?

  ANON_ACTIONS = ([:index, :mcp_connect] + TOPICS.map(&:to_sym)).freeze
  allows_anonymous(*ANON_ACTIONS)
  before_action :set_no_cache_headers, only: ANON_ACTIONS
  before_action { @sidebar_mode = "minimal" }
  # Help is intentionally NOT rate-limited: small static surface, unlikely
  # abuse target. Rack::Attack's 300/min/IP throttle is the backstop.

  def index
    @page_title = "Help"
    respond_to do |format|
      format.html { render_help_html("index") }
      format.md
    end
  end

  TOPICS.each do |topic|
    define_method(topic) do
      return render("shared/404", status: :not_found) unless help_topic_available?(topic)
      @page_title = "Help — #{TOPIC_DISPLAY_NAMES[topic] || topic.titleize}"
      respond_to do |format|
        format.html { render_help_html(topic) }
        format.md
      end
    end
  end

  # Per-harness MCP Connect setup guide. URL: /help/mcp/connect/:harness.
  def mcp_connect
    harness_key = params[:harness].to_s
    return render("shared/404", status: :not_found) unless Mcp::Connect.supported?(harness_key)
    return render("shared/404", status: :not_found) unless help_topic_available?("mcp")

    @harness_key = harness_key
    @harness_name = Mcp::Connect.display_name(harness_key)
    @page_title = "Help — Connect #{@harness_name}"
    @breadcrumb_items = [
      ["Home", "/"],
      ["Help", "/help"],
      ["MCP", "/help/mcp"],
      "Connect #{@harness_name}",
    ]
    template = "help/mcp_connect/#{harness_key.tr('-', '_')}"
    respond_to do |format|
      format.html do
        markdown_content = render_to_string(template: template, formats: [:md], layout: false)
        @help_html = MarkdownRenderer.render(markdown_content, shift_headers: false, display_references: false)
        @page_description ||= excerpt(markdown_content, max: 200)
        render template: "help/show"
      end
      format.md { render template: template }
    end
  end

  def help_topic_available?(topic)
    return current_tenant.any_ai_agents_enabled? if topic.to_s == "agents"

    flag = FEATURE_GATED_TOPICS[topic.to_s]
    return true if flag.nil?

    current_tenant.feature_enabled?(flag)
  end

  private

  def render_help_html(topic)
    markdown_content = render_to_string(template: "help/#{topic}", formats: [:md], layout: false)
    @help_html = MarkdownRenderer.render(markdown_content, shift_headers: false, display_references: false)
    @page_description ||= excerpt(markdown_content, max: 200)
    render template: "help/show"
  end
end
