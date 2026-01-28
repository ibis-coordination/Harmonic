# typed: false

class WhoamiController < ApplicationController
  layout "pulse"

  def index
    @page_title = "Who Am I?"
    @sidebar_mode = "minimal"
    respond_to do |format|
      format.html do
        render inline: page_html, layout: true
      end
      format.md
    end
  end

  private

  def page_html
    markdown(render_to_string("whoami/index", layout: false, formats: [:md]))
  end

  def markdown(text)
    MarkdownRenderer.render(text, shift_headers: false).html_safe
  end

  def current_resource_model
    User
  end
end
