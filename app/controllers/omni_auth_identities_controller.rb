class OmniAuthIdentitiesController < ApplicationController
  def new
  end

  private

  def is_auth_controller?
    true
  end
end