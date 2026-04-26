# typed: false

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_tenant_context
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      user_id = request.session[:user_id]
      user = User.find_by(id: user_id, user_type: "human") if user_id.present?
      user || reject_unauthorized_connection
    end

    def set_tenant_context
      subdomain = request.subdomain
      Tenant.scope_thread_to_tenant(subdomain: subdomain) if subdomain.present?
    end
  end
end
