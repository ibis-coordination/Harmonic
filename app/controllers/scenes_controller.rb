# typed: false

class ScenesController < ApplicationController
  before_action :set_sidebar_mode, only: [:index, :new]

  def index
    @page_title = "Scenes"
    @scenes = Superagent.where(superagent_type: 'scene').limit(20)
    respond_to do |format|
      format.html
      format.md
    end
  end

  def actions_index
    @page_title = "Actions | Scenes"
    render_actions_index({
      actions: [
        ActionsHelper.action_description("create_scene"),
      ],
    })
  end

  def new
  end

  def create
    scene = api_helper.create_scene
    redirect_to scene.path
  end

  def show
    return render 'shared/404' unless @current_superagent.superagent_type == 'scene'
    @page_title = @current_superagent.name
    @notes = @current_superagent.recent_notes.where(commentable_id: nil).order(created_at: :desc)
    respond_to do |format|
      format.html
      format.md
    end
  end

  private

  def set_sidebar_mode
    @sidebar_mode = 'minimal'
  end
end