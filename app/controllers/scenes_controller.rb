# typed: false

class ScenesController < ApplicationController
  def index
    @page_title = "Scenes"
    @scenes = Studio.where(studio_type: 'scene').limit(20)
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
    return render 'shared/404' unless @current_studio.studio_type == 'scene'
    @page_title = @current_studio.name
    @notes = @current_studio.recent_notes.where(commentable_id: nil).order(created_at: :desc)
    respond_to do |format|
      format.html
      format.md
    end
  end
end