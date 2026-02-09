# typed: false

class Api::AppAdmin::TenantsController < Api::AppAdminController
  before_action :set_tenant, only: [:show, :update, :destroy, :suspend, :activate]

  # GET /api/app_admin/tenants
  def index
    tenants = Tenant.all.order(created_at: :desc)
    render json: { tenants: tenants.map { |t| tenant_json(t) } }
  end

  # POST /api/app_admin/tenants
  def create
    tenant = Tenant.new(tenant_params)

    if tenant.save
      render json: tenant_json(tenant), status: :created
    else
      render json: { errors: tenant.errors.full_messages }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    render json: { errors: ["Subdomain has already been taken"] }, status: :unprocessable_entity
  end

  # GET /api/app_admin/tenants/:id
  def show
    render json: tenant_json(@tenant)
  end

  # PATCH /api/app_admin/tenants/:id
  def update
    if @tenant.update(tenant_params)
      render json: tenant_json(@tenant)
    else
      render json: { errors: @tenant.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/app_admin/tenants/:id
  def destroy
    @tenant.destroy
    head :no_content
  end

  # POST /api/app_admin/tenants/:id/suspend
  def suspend
    reason = params[:reason]
    @tenant.suspend!(reason: reason)
    render json: tenant_json(@tenant)
  end

  # POST /api/app_admin/tenants/:id/activate
  def activate
    @tenant.activate!
    render json: tenant_json(@tenant)
  end

  private

  def set_tenant
    # Support lookup by ID or subdomain
    @tenant = Tenant.find_by(id: params[:id]) ||
              Tenant.find_by(subdomain: params[:id])

    render_not_found("Tenant not found") unless @tenant
  end

  def tenant_params
    params.permit(:subdomain, :name)
  end

  def tenant_json(tenant)
    {
      id: tenant.id,
      subdomain: tenant.subdomain,
      name: tenant.name,
      suspended_at: tenant.suspended_at,
      suspended_reason: tenant.suspended_reason,
      created_at: tenant.created_at,
      updated_at: tenant.updated_at,
    }
  end
end
