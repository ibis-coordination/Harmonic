# typed: false

module Api::V1
  class VotesController < BaseController
    def create
      begin
        vote = api_helper.vote
        render json: vote
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: 400
      end
    end

    def update
      vote = Vote.where(associations).find_by(id: params[:id])
      return render json: { error: 'Vote not found' }, status: 404 unless vote
      vote.accepted = params[:accepted] if params[:accepted].present?
      vote.preferred = params[:preferred] if params[:preferred].present?
      ActiveRecord::Base.transaction do
        vote.save!
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'vote',
              superagent_id: current_superagent.id,
              main_resource: {
                type: 'Decision',
                id: current_decision.id,
                truncated_id: current_decision.truncated_id,
              },
              sub_resources: [
                {
                  type: 'Option',
                  id: current_option.id,
                },
                {
                  type: 'Vote',
                  id: vote.id,
                },
              ],
            }
          )
        end
      end
      render json: vote
    end

    private

    def associations
      @associations ||= {
        decision: current_decision,
        option: current_option,
        decision_participant: current_decision_participant,
      }
    end

    def current_scope
      return @current_scope if defined?(@current_scope)
      @current_scope = super
      @current_scope = @current_scope.where(option: current_option) if current_option
      @current_scope = @current_scope.where(decision_participant: current_decision_participant) if current_decision_participant
      @current_scope
    end

  end
end
