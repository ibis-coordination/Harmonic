# typed: true

class Scene < Collective

  default_scope do
    s = where(collective_type: 'scene')
    if Tenant.current_id
      s = where(tenant_id: Tenant.current_id)
    end
    s
  end

end