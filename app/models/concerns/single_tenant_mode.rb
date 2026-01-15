# typed: strict

module SingleTenantMode
  extend ActiveSupport::Concern
  extend T::Sig

  class_methods do
    extend T::Sig

    sig { returns(T::Boolean) }
    def single_tenant_mode?
      ENV["SINGLE_TENANT_MODE"] == "true"
    end

    sig { returns(T.nilable(String)) }
    def single_tenant_subdomain
      ENV.fetch("PRIMARY_SUBDOMAIN", nil)
    end
  end
end
