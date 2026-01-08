# typed: false

class LearnController < ApplicationController
  def index
    render layout: 'application', html: (
      markdown(render_to_string('learn/index', layout: false, formats: [:md]))
    )
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
    render layout: 'application', html: page_html
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