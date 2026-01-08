# typed: false

class OmniAuthIdentitiesController < ApplicationController
  def new
  end

  def failed_registration
    # This is called when OmniAuth identity registration fails
    @identity = OmniAuthIdentity.new(env['omniauth.identity'])
    render :new
  end

  private

  def is_auth_controller?
    true
  end
end