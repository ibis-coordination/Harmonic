# typed: false

class AskController < ApplicationController
  def index
    @page_title = "Ask Harmonic"
    @question = nil
    @answer = nil
  end

  def create
    question = params[:question]

    respond_to do |format|
      format.html do
        @page_title = "Ask Harmonic"
        @question = question
        if question.blank?
          @answer = nil
          flash.now[:alert] = "Please enter a question."
        else
          @answer = LlmClient.new.ask(question)
        end
        render :index
      end

      format.json do
        if question.blank?
          render json: { success: false, error: "Please enter a question." }, status: :unprocessable_entity
        else
          answer = LlmClient.new.ask(question)
          render json: { success: true, question: question, answer: answer }
        end
      end
    end
  end
end
