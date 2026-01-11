# typed: false

class LearnController < ApplicationController
  def index
    @page_title = 'Learn'
    respond_to do |format|
      format.html do
        render layout: 'application', html: (
          markdown(render_to_string('learn/index', layout: false, formats: [:md]))
        )
      end
      format.md
    end
  end

  def awareness_indicators
    show
  end

  def acceptance_voting
    show
  end

  def reciprocal_commitment
    show
  end

  private

  def show
    @page_title = params[:action].titleize
    respond_to do |format|
      format.html do
        render layout: 'application', html: page_html
      end
      format.md
    end
  end

  def page_html
    markdown(page_text)
  end

  def markdown(text)
    MarkdownRenderer.render(text, shift_headers: false).html_safe
  end

  def page_text
    File.read(Rails.root.join('app', 'views', 'learn', params[:action] + '.md'))
  end

  def current_resource_model
    Note
  end
end