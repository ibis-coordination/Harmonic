# typed: false

module Api::V1
  class DecisionsController < BaseController
    def index
      index_not_supported_404
    end

    def create
      begin
        decision = api_helper.create_decision
        render json: decision
      rescue ActiveRecord::RecordInvalid => e
        # TODO - Detect specific validation errors and return helpful error messages
        render json: { error: 'There was an error creating the decision. Please try again.' }, status: 400
      end
    end

    def update
      decision = current_decision
      return render json: { error: 'Decision not found' }, status: 404 unless decision
      return render json: { error: 'Unauthorized' }, status: 403 unless decision.can_edit_settings?(@current_user)
      updatable_attributes.each do |attribute|
        decision[attribute] = params[attribute] if params.has_key?(attribute)
      end
      decision.updated_by = current_user
      ActiveRecord::Base.transaction do
        decision.save!
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'update',
              superagent_id: current_superagent.id,
              main_resource: {
                type: 'Decision',
                id: decision.id,
                truncated_id: decision.truncated_id,
              },
              sub_resources: [],
            }
          )
        end
      end
      render json: decision
    end

    private

    def updatable_attributes
      [:question, :description, :options_open, :deadline]
    end
  end
end
