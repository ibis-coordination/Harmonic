# typed: false

module Api::V1
  class CollectivesController < BaseController
    def index
      render json: current_user.collectives.listable.map(&:api_json)
    end

    def show
      collective = current_user.collectives.find_by(id: params[:id])
      collective ||= current_user.collectives.find_by(handle: params[:id])
      return render json: { error: 'Collective not found' }, status: 404 unless collective
      render json: collective.api_json(include: includes_param)
    end

    def create
      return render json: { error: 'Handle is not available' }, status: 400 unless Collective.handle_available?(params[:handle])
      begin
        collective = api_helper.create_collective
        render json: collective.api_json
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: 400
      end
    end

    def update
      collective = current_user.collectives.find_by(id: params[:id])
      collective ||= current_user.collectives.find_by(handle: params[:id])
      return render json: { error: 'Collective not found' }, status: 404 unless collective
      collective.name = params[:name] if params.has_key?(:name)
      collective.description = params[:description] if params.has_key?(:description)
      collective.timezone = params[:timezone] if params.has_key?(:timezone)
      collective.tempo = params[:tempo] if params.has_key?(:tempo)
      collective.synchronization_mode = params[:synchronization_mode] if params.has_key?(:synchronization_mode)
      if params.has_key?(:handle) && params[:handle] != collective.handle
        if params[:force_update] == true
          collective.handle = params[:handle]
        else
          error_message = "Changing a collective's handle can break some functionality (including links) and is not recommended. " +
                          "Once changed, the old handle will become available for others to claim for a different collective. " +
                          "If you are sure you want to do this, include '\"force_update\": true' in your request."
          return render json: { error: error_message }, status: 400
        end
      end
      if collective.changed?
        collective.save!
      end
      render json: collective.api_json
    end

    def destroy
      collective = current_user.collectives.find_by(id: params[:id])
      collective ||= current_user.collectives.find_by(handle: params[:id])
      return render json: { error: 'Collective not found' }, status: 404 unless collective
      collective.delete!
      render json: { message: 'Collective deleted' }
    end

    private

    def updatable_attributes
      [:name, :handle]
    end
  end
end
