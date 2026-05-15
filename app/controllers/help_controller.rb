# typed: false

class HelpController < ApplicationController
  TOPICS = %w[
    privacy collectives notes reminder_notes table_notes
    decisions executive_decisions lottery_decisions
    commitments cycles search links
    agents trio automations api rest_api markdown_ui notifications representation
  ].freeze

  # Topics that are only available when a feature flag is enabled.
  # The hidden topic returns 404 and is omitted from the index — see app/views/help/index.md.erb.
  FEATURE_GATED_TOPICS = {
    "api" => "api",
    "rest_api" => "api",
    "agents" => "ai_agents",
    "trio" => "trio",
  }.freeze

  helper_method :help_topic_available?

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
    flag = FEATURE_GATED_TOPICS[topic.to_s]
    return true if flag.nil?

    current_tenant.feature_enabled?(flag)
  end

  private

  def render_help_html(topic)
    markdown_content = render_to_string(template: "help/#{topic}", formats: [:md], layout: false)
    @help_html = MarkdownRenderer.render(markdown_content, shift_headers: false, display_references: false)
    render template: "help/show"
  end
end
