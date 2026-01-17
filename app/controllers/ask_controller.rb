# typed: false

class AskController < ApplicationController
  def index
    @page_title = "Ask Harmonic"
    @question = nil
    @answer = nil
  end

  def create
    @page_title = "Ask Harmonic"
    @question = params[:question]

    if @question.blank?
      @answer = nil
      flash.now[:alert] = "Please enter a question."
    else
      @answer = LlmClient.new.ask(@question)
    end

    render :index
  end
end
