# typed: false

class HeartbeatsController < ApplicationController
  def index
    @page_title = 'Heartbeats'
    @current_heartbeat = current_heartbeat
    respond_to do |format|
      format.html
      format.md
    end
  end

  # def show
  #   @heartbeat =
  # end

  def create
    if current_heartbeat
      return render status: 409, json: { error: "Heartbeat already exists" }
    end
    other_heartbeats = Heartbeat.current_for_studio(current_studio).count
    heartbeat = api_helper.create_heartbeat
    render json: {
      expires_at: heartbeat.expires_at,
      other_heartbeats: other_heartbeats,
      cycle_display_name: current_cycle.display_name.downcase,
    }
  end

  def create_heartbeat
    begin
      heartbeat = api_helper.create_heartbeat
      render_action_success({
        action_name: 'create_heartbeat',
        resource: heartbeat,
        result: "heartbeat created.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'create_heartbeat',
        resource: current_heartbeat,
        error: e.message,
      })
    end
  end

  def describe_create_heartbeat
    render_action_description({
      action_name: 'create_heartbeat',
      description: "Create a new heartbeat",
      params: []
    })
  end
end