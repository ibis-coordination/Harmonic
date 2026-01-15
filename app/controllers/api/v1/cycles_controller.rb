# typed: false

module Api::V1
  class CyclesController < BaseController
    def index
      response = ['today', 'this-week', 'this-month', 'this-year'].map do |name|
        Cycle.new(
          name: name,
          tenant: @current_tenant,
          superagent: @current_superagent,
          current_user: @current_user,
          params: {
            filters: params[:filters],
            sort_by: params[:sort_by],
          }
        ).api_json(include: includes_param)
      end
      render json: response
    end

    def show
      cycle = Cycle.new(name: params[:id], tenant: @current_tenant, superagent: @current_superagent)
      render json: cycle.api_json(include: ['notes', 'decisions', 'commitments', 'backlinks'])
    end

    def create
      render_404
    end

    def update
      render_404
    end

    def destroy
      render_404
    end

  end
end
