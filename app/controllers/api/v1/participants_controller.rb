# typed: false

module Api::V1
  class ParticipantsController < BaseController
    # Participants are read only
    def create
      render_404
    end

    def update
      render_404
    end

    def destroy
      render_404
    end

    private

    def current_scope
      if current_decision
        current_decision.participants
      elsif current_commitment
        current_commitment.participants
      end
    end

    def current_resource
      current_scope.find_by(id: params[:id])
    end

    def current_resource_model
      if current_decision
        DecisionParticipant
      elsif current_commitment
        CommitmentParticipant
      end
    end

    def current_commitment
      return @current_commitment if defined?(@current_commitment)
      commitment_id = params[:commitment_id]
      return @current_commitment = nil unless commitment_id
      @current_commitment = Commitment.find(commitment_id)
    end

    def current_decision
      return @current_decision if defined?(@current_decision)
      decision_id = params[:decision_id]
      return @current_decision = nil unless decision_id
      @current_decision = Decision.find(decision_id)
    end

  end
end