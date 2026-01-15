# typed: true

class Scene < Superagent

  default_scope do
    s = where(superagent_type: 'scene')
    if Tenant.current_id
      s = where(tenant_id: Tenant.current_id)
    end
    s
  end

end