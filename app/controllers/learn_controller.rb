# typed: false

class LearnController < ApplicationController
  before_action :set_sidebar_mode

  def index
    @page_title = 'Learn'
    respond_to do |format|
      format.html do
        @content = markdown(render_to_string('learn/index', layout: false, formats: [:md]))
        render 'learn/show'
      end
      format.md
    end
  end

  def awareness_indicators
    show_page
  end

  def acceptance_voting
    show_page
  end

  def reciprocal_commitment
    show_page
  end

  def memory
    show_page
  end

  def subagency
    @page_title = "Subagency"
    respond_to do |format|
      format.html do
        @content = page_html_erb("subagency")
        render 'learn/show'
      end
      format.md { render "learn/subagency" }
    end
  end

  def superagency
    @page_title = "Superagency"
    respond_to do |format|
      format.html do
        @content = page_html_erb("superagency")
        render 'learn/show'
      end
      format.md { render "learn/superagency" }
    end
  end

  private

  def set_sidebar_mode
    @sidebar_mode = 'minimal'
  end

  def show_page
    @page_title = params[:action].titleize
    respond_to do |format|
      format.html do
        @content = page_html
        render 'learn/show'
      end
      format.md
    end
  end

  def page_html
    markdown(page_text)
  end

  def page_html_erb(template)
    markdown(render_to_string("learn/#{template}", layout: false, formats: [:md]))
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
