# typed: false

module Api::V1
  class StudiosController < BaseController
    def index
      render json: current_user.studios.map(&:api_json)
    end

    def show
      studio = current_user.studios.find_by(id: params[:id])
      studio ||= current_user.studios.find_by(handle: params[:id])
      return render json: { error: 'Studio not found' }, status: 404 unless studio
      render json: studio.api_json(include: includes_param)
    end

    def create
      handle_available = Studio.where(handle: params[:handle]).empty?
      return render json: { error: 'Handle already in use' }, status: 400 unless handle_available
      begin
        studio = api_helper.create_studio
        render json: studio.api_json
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: 400
      end
    end

    def update
      studio = current_user.studios.find_by(id: params[:id])
      studio ||= current_user.studios.find_by(handle: params[:id])
      return render json: { error: 'Studio not found' }, status: 404 unless note
      studio.name = params[:name] if params.has_key?(:name)
      studio.description = params[:description] if params.has_key?(:description)
      studio.timezone = params[:timezone] if params.has_key?(:timezone)
      studio.tempo = params[:tempo] if params.has_key?(:tempo)
      studio.synchronization_mode = params[:synchronization_mode] if params.has_key?(:synchronization_mode)
      if params.has_key?(:handle) && params[:handle] != studio.handle
        if params[:force_update] == true
          studio.handle = params[:handle]
        else
          error_message = "Changing a studio's handle can break some functionality (including links) and is not recommended. " +
                          "Once changed, the old handle will become available for others to claim for a different studio. " +
                          "If you are sure you want to do this, include '\"force_update\": true' in your request."
          return render json: { error: error_message }, status: 400
        end
      end
      if studio.changed?
        studio.save!
      end
      render json: studio.api_json
    end

    def destroy
      studio = current_user.studios.find_by(id: params[:id])
      studio ||= current_user.studios.find_by(studio: params[:id])
      return render json: { error: 'Studio not found' }, status: 404 unless studio
      studio.delete!
      render json: { message: 'Studio deleted' }
    end

    private

    def updatable_attributes
      [:name, :handle]
    end
  end
end
