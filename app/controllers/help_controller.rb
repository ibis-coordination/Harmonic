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

  helper_method :help_topic_available?

  ANON_ACTIONS = ([:index] + TOPICS.map(&:to_sym)).freeze
  allows_anonymous(*ANON_ACTIONS)
  before_action :set_no_cache_headers, only: ANON_ACTIONS
  # Help is intentionally NOT rate-limited: small static surface, unlikely
  # abuse target. Rack::Attack's 300/min/IP throttle is the backstop.

  def index
    @page_title = "Help"
    @sidebar_mode = "minimal"
    respond_to do |format|
      format.html { render_help_html("index") }
      format.md
    end
  end

  TOPICS.each do |topic|
    define_method(topic) do
      unless help_topic_available?(topic)
        @sidebar_mode = "minimal"
        render "shared/404", status: :not_found
        return
      end
      @page_title = "Help — #{topic.titleize}"
      @sidebar_mode = "minimal"
      respond_to do |format|
        format.html { render_help_html(topic) }
        format.md
      end
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
