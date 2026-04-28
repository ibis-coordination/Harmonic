# typed: false

class HelpController < ApplicationController
  TOPICS = %w[privacy collectives notes table_notes decisions commitments cycles search links agents api].freeze

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
      @page_title = "Help — #{topic.titleize}"
      @sidebar_mode = "minimal"
      respond_to do |format|
        format.html { render_help_html(topic) }
        format.md
      end
    end
  end

  private

  def render_help_html(topic)
    markdown_content = render_to_string(template: "help/#{topic}", formats: [:md], layout: false)
    @help_html = MarkdownRenderer.render(markdown_content, shift_headers: false, display_references: false)
    render template: "help/show"
  end
end
