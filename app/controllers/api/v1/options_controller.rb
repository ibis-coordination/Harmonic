# typed: false

module Api::V1
  class OptionsController < BaseController
    def create
      if current_decision.can_add_options?(current_decision_participant)
        option = api_helper.create_decision_option
        render json: option
      else
        render json: { error: 'Cannot add options' }, status: 403
      end
    end

    def update
      if current_decision.can_update_options?(current_decision_participant)
        option = current_resource
        api_helper.update_option(option)
        render json: option.reload
      else
        render json: { error: 'Cannot update options' }, status: 403
      end
    rescue StandardError => e
      render json: { error: e.message }, status: 400
    end

    def destroy
      if current_decision.can_delete_options?(current_decision_participant)
        option = current_resource
        api_helper.delete_option(option)
        render json: { success: true }
      else
        render json: { error: 'Cannot delete options' }, status: 403
      end
    rescue StandardError => e
      render json: { error: e.message }, status: 400
    end
  end
end
