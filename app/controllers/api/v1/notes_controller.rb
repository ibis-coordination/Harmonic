module Api::V1
  class NotesController < BaseController
    def index
      index_not_supported_404
    end

    def create
      begin
        note = api_helper.create_note
        render json: note.api_json
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: 400
      end
    end

    def update
      note = current_note
      return render json: { error: 'Note not found' }, status: 404 unless note
      updatable_attributes.each do |attribute|
        note[attribute] = params[attribute] if params.has_key?(attribute)
      end
      if note.changed?
        note.updated_by = current_user
        ActiveRecord::Base.transaction do
          note.save!
          if current_representation_session
            current_representation_session.record_activity!(
              request: request,
              semantic_event: {
                timestamp: Time.current,
                event_type: 'update',
                studio_id: current_studio.id,
                main_resource: {
                  type: 'Note',
                  id: note.id,
                  truncated_id: note.truncated_id,
                },
                sub_resources: [],
              }
            )
          end
        end
      end
      render json: note.api_json
    end

    def confirm
      history_event = api_helper.confirm_read
      render json: history_event.api_json
    end

    private

    def updatable_attributes
      [:title, :text, :deadline]
    end
  end
end
