# typed: false

class Scene < Studio

  default_scope do
    s = where(studio_type: 'scene')
    if Tenant.current_id
      s = where(tenant_id: Tenant.current_id)
    end
    s
  end

end