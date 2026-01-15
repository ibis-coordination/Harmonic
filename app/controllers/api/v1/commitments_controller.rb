# typed: false

module Api::V1
  class CommitmentsController < BaseController
    def index
      index_not_supported_404
    end

    def create
      ActiveRecord::Base.transaction do
        commitment = Commitment.create!(
          title: params[:title],
          description: params[:description],
          deadline: params[:deadline],
          critical_mass: params[:critical_mass],
          created_by: current_user,
        )
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'create',
              superagent_id: current_superagent.id,
              main_resource: {
                type: 'Commitment',
                id: commitment.id,
                truncated_id: commitment.truncated_id,
              },
              sub_resources: [],
            }
          )
        end
        render json: commitment.api_json
      rescue ActiveRecord::RecordInvalid => e
        # TODO - Detect specific validation errors and return helpful error messages
        render json: { error: 'There was an error creating the commitment. Please try again.' }, status: 400
      end
    end

    def update
      commitment = current_commitment
      return render json: { error: 'Commitment not found' }, status: 404 unless commitment
      return render json: { error: 'Unauthorized' }, status: 403 unless commitment.can_edit_settings?(@current_user)
      updatable_attributes.each do |attribute|
        commitment[attribute] = params[attribute] if params.has_key?(attribute)
      end
      commitment.close_if_limit_reached
      if commitment.changed?
        commitment.updated_by = current_user
        ActiveRecord::Base.transaction do
          commitment.save!
          if current_representation_session
            current_representation_session.record_activity!(
              request: request,
              semantic_event: {
                timestamp: Time.current,
                event_type: 'update',
                superagent_id: current_superagent.id,
                main_resource: {
                  type: 'Commitment',
                  id: commitment.id,
                  truncated_id: commitment.truncated_id,
                },
                sub_resources: [],
              }
            )
          end
        end
      end
      render json: commitment.api_json
    end

    def join
      commitment = current_commitment
      return render json: { error: 'Commitment not found' }, status: 404 unless commitment
      if commitment.closed?
        return render json: { error: 'This commitment is closed.' }, status: 400
      end
      commitment_participant = current_commitment_participant
      commitment_participant.committed = true if params[:committed].to_s == 'true'
      ActiveRecord::Base.transaction do
        commitment_participant.save!
        commitment.close_if_limit_reached!
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'commit',
              superagent_id: current_superagent.id,
              main_resource: {
                type: 'Commitment',
                id: commitment.id,
                truncated_id: commitment.truncated_id,
              },
              sub_resources: [
                {
                  type: 'CommitmentParticipant',
                  id: commitment_participant.id,
                }
              ],
            }
          )
        end
      end
      render json: commitment_participant.api_json
    end

    private

    def updatable_attributes
      [:title, :description, :deadline, :critical_mass]
    end
  end
end
