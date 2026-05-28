# typed: false

class MottoController < ApplicationController
  allows_anonymous :index
  before_action :set_no_cache_headers, only: [:index]

  def index
    @page_title = "Do the right thing. ❤️"
    @sidebar_mode = "minimal"
    markdown_source = render_to_string("motto/index", layout: false, formats: [:md])
    @page_description ||= excerpt(markdown_source, max: 200)
    respond_to do |format|
      format.html do
        render inline: markdown(markdown_source), layout: true
      end
      format.md
    end
  end

  private

  def markdown(text)
    MarkdownRenderer.render(text, shift_headers: false).html_safe
  end

  def current_resource_model
    nil
  end
end
