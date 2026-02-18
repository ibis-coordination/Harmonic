# typed: false

class HeartbeatsController < ApplicationController
  before_action :set_sidebar_mode, only: [:index]

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
    other_heartbeats = Heartbeat.current_for_collective(current_collective).count
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
    render_action_description(ActionsHelper.action_description("send_heartbeat"))
  end

  private

  def set_sidebar_mode
    @sidebar_mode = 'settings'
    @team = @current_collective.team
  end
end