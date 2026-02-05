# typed: false

class OmniAuthIdentitiesController < ApplicationController
  before_action :set_auth_layout

  def new
  end

  def failed_registration
    # This is called when OmniAuth identity registration fails
    @identity = request.env['omniauth.identity']
    render :new
  end

  private

  def set_auth_layout
    @sidebar_mode = 'none'
    @hide_header = true
  end

  def is_auth_controller?
    true
  end
end