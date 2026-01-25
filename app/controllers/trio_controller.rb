# typed: false

class TrioController < ApplicationController
  layout 'pulse', only: [:index]
  before_action :require_trio_enabled
  before_action :set_sidebar_mode, only: [:index]

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
          @answer = ask_harmonic(question)
        end
        render :index
      end

      format.json do
        if question.blank?
          render json: { success: false, error: "Please enter a question." }, status: :unprocessable_entity
        else
          result = trio_client.ask_with_details(
            question,
            aggregation_method: params[:aggregation_method].presence,
            judge_model: params[:judge_model].presence,
            synthesize_model: params[:synthesize_model].presence
          )
          voting = result.voting_details
          render json: {
            success: true,
            question: question,
            answer: result.content,
            aggregation_method: voting&.aggregation_method,
            winner_index: voting&.winner_index,
            candidates: voting&.candidates,
          }
        end
      end
    end
  end

  private

  def set_sidebar_mode
    @sidebar_mode = 'none'
  end

  def require_trio_enabled
    return if @current_tenant&.trio_enabled?

    @sidebar_mode = 'none'
    respond_to do |format|
      format.html { render "shared/403", status: :forbidden }
      format.md { render "shared/403", status: :forbidden }
      format.json { render json: { error: "Trio AI is not enabled for this tenant" }, status: :forbidden }
    end
  end

  def trio_client
    @trio_client ||= TrioClient.new
  end

  def ask_harmonic(question)
    response = trio_client.ask(question, system_prompt: HarmonicAssistant.system_prompt)
    HarmonicAssistant.strip_thinking(response)
  end
end
