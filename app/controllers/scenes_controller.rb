class ScenesController < ApplicationController
  def index
    @scenes = Studio.where(studio_type: 'scene').limit(20)
  end

  def new
  end

  def create
    scene = api_helper.create_scene
    redirect_to scene.path
  end

  def show
    return render 'shared/404' unless @current_studio.studio_type == 'scene'
    @notes = @current_studio.recent_notes.order(created_at: :desc)
  end
end