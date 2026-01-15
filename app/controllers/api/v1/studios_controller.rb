# typed: false

module Api::V1
  class StudiosController < BaseController
    def index
      render json: current_user.superagents.map(&:api_json)
    end

    def show
      superagent = current_user.superagents.find_by(id: params[:id])
      superagent ||= current_user.superagents.find_by(handle: params[:id])
      return render json: { error: 'Studio not found' }, status: 404 unless superagent
      render json: superagent.api_json(include: includes_param)
    end

    def create
      handle_available = Superagent.where(handle: params[:handle]).empty?
      return render json: { error: 'Handle already in use' }, status: 400 unless handle_available
      begin
        superagent = api_helper.create_studio
        render json: superagent.api_json
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: 400
      end
    end

    def update
      superagent = current_user.superagents.find_by(id: params[:id])
      superagent ||= current_user.superagents.find_by(handle: params[:id])
      return render json: { error: 'Studio not found' }, status: 404 unless superagent
      superagent.name = params[:name] if params.has_key?(:name)
      superagent.description = params[:description] if params.has_key?(:description)
      superagent.timezone = params[:timezone] if params.has_key?(:timezone)
      superagent.tempo = params[:tempo] if params.has_key?(:tempo)
      superagent.synchronization_mode = params[:synchronization_mode] if params.has_key?(:synchronization_mode)
      if params.has_key?(:handle) && params[:handle] != superagent.handle
        if params[:force_update] == true
          superagent.handle = params[:handle]
        else
          error_message = "Changing a studio's handle can break some functionality (including links) and is not recommended. " +
                          "Once changed, the old handle will become available for others to claim for a different studio. " +
                          "If you are sure you want to do this, include '\"force_update\": true' in your request."
          return render json: { error: error_message }, status: 400
        end
      end
      if superagent.changed?
        superagent.save!
      end
      render json: superagent.api_json
    end

    def destroy
      superagent = current_user.superagents.find_by(id: params[:id])
      superagent ||= current_user.superagents.find_by(handle: params[:id])
      return render json: { error: 'Studio not found' }, status: 404 unless superagent
      superagent.delete!
      render json: { message: 'Studio deleted' }
    end

    private

    def updatable_attributes
      [:name, :handle]
    end
  end
end
