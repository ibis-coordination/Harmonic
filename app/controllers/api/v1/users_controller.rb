# typed: false

module Api::V1
  class UsersController < BaseController
    def index
      render json: current_tenant.team.map(&:api_json)
    end

    def show
      user = current_tenant.users.find_by(id: params[:id])
      return render json: { error: 'User not found' }, status: 404 unless user

      render json: user.api_json
    end
  end
end
