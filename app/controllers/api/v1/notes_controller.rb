# typed: false

module Api::V1
  class NotesController < BaseController
    def index
      index_not_supported_404
    end

    def create
      note = api_helper.create_note
      render json: note.api_json
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: 400
    end

    def update
      note = api_helper.update_note
      render json: note.api_json
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Note not found' }, status: 404
    rescue StandardError => e
      if e.message.include?('Unauthorized')
        render json: { error: 'Unauthorized' }, status: 403
      else
        render json: { error: e.message }, status: 400
      end
    end

    def confirm
      history_event = api_helper.confirm_read
      render json: history_event.api_json
    end
  end
end
