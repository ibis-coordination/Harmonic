# typed: true

module Api::V1
  class InfoController < BaseController
    extend T::Sig

    def index
      # TODO Use token scopes to determine what to show
      render json: {
        name: 'Harmonic Team API',
        version: '1.0.0', # TODO: Use config variable to track version
        routes: [
          {
            path: '/api/v1',
            methods: ['GET'],
          },
          {
            path: '/api/v1/decisions/:decision_id',
            methods: ['GET', 'PUT', 'DELETE'],
          },
          {
            path: '/api/v1/decisions/:decision_id/options',
            methods: ['GET', 'POST'],
          },
          {
            path: '/api/v1/decisions/:decision_id/options/:option_id',
            methods: ['GET', 'PUT', 'DELETE'],
          },
          {
            path: '/api/v1/decisions/:decision_id/options/:option_id/votes',
            methods: ['GET', 'POST'],
          },
          {
            path: '/api/v1/decisions/:decision_id/options/:option_id/votes/:vote_id',
            methods: ['GET', 'PUT', 'DELETE'],
          },
          {
            path: '/api/v1/decisions/:decision_id/participants',
            methods: ['GET', 'POST'],
          },
          {
            path: '/api/v1/decisions/:decision_id/participants/:participant_id',
            methods: ['GET', 'PUT', 'DELETE'],
          },
          {
            path: '/api/v1/decisions/:decision_id/participants/:participant_id/votes',
            methods: ['GET', 'POST'],
          },
          {
            path: '/api/v1/decisions/:decision_id/participants/:participant_id/votes/:vote_id',
            methods: ['GET', 'PUT', 'DELETE'],
          },
          {
            path: '/api/v1/decisions/:decision_id/results',
            methods: ['GET'],
          },
        ]
      }
    end

    private

    def current_resource_model
      nil
    end

    def validate_scope
      return true
    end

    def current_scope
      nil
    end

    def current_resource
      nil
    end

  end
end