# typed: false

# Does not inherit from ApplicationController
class HealthcheckController < ActionController::Base
  def healthcheck
    # Check the database connection
    ActiveRecord::Base.connection.execute('SELECT 1')
    render json: { status: 'ok' }
  end
end