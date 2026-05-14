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
  end
end
