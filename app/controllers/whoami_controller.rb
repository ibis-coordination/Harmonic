# typed: false

class WhoamiController < ApplicationController
  def index
    @page_title = "Who Am I?"
    respond_to do |format|
      format.html do
        render layout: "application", html: page_html
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
