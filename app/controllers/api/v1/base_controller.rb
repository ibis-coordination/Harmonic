# typed: false

class Api::V1::BaseController < ApplicationController
  before_action :api_authorize!, if: :api_token_present?

  # Read actions are allowed by default
  def index
    response = current_scope.map do |resource|
      resource.api_json(include: includes_param)
    end
    render json: response
  end

  def show
    render json: current_resource.api_json(include: includes_param)
  end

  # Write actions are not allowed by default
  def create
    render_404
  end

  def update
    render_404
  end

  def destroy
    render_404
  end

  private

  def render_404
    render json: { error: 'Not found' }, status: 404
  end

  def index_not_supported_404
    render status: 404, json: {
      message: 'The index action is not supported for notes, decisions, or commitments. Please use the /api/v1/cycles/today endpoint to get a collection of notes, decisions, and commitments.',
    }
  end

  CONTROLLER_MODEL_MAPPING = {
    "Studio" => Collective,
  }.freeze

  def current_resource_model
    model_name = self.class.name.sub('Api::V1::', '').sub('Controller', '').singularize
    CONTROLLER_MODEL_MAPPING[model_name] || model_name.constantize
  end

  def current_scope
    current_resource_model.where(decision: current_decision)
  end

  def current_option
    return @current_option if defined?(@current_option)
    if current_resource_model == Option
      @current_option = current_resource
    elsif params[:option_id].present?
      o = Option.where(decision: current_decision)
      @current_option = o.find_by(id: params[:option_id])
    else
      @current_option = nil
    end
    @current_option
  end

  def includes_param
    params[:include].to_s.split(',')
  end

  def request_context_for_history_events
    {
      request_id: request.request_id,
      method: request.method,
      url: request.url,
      path: request.path,
      user_id: @current_user.id,
      token_id: @current_token.id,
    }
  end
end
