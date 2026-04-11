# typed: false

module Api::V1
  class UsersController < BaseController
    def index
      render json: current_tenant.team.map(&:api_json)
    end

    def show
      user = current_tenant.users.find_by(id: params[:id])
      return render json: { error: 'User not found' }, status: 404 unless user
      render json: user.api_json
    end

    def create
      # Only AI agent users can be created via the API
      begin
        # Billing gate: require active subscription when stripe_billing is enabled
        if current_user.requires_stripe_billing?(current_tenant)
          return render json: { error: "Billing is not set up. Please set up billing at /billing before creating AI agents." }, status: 403
        end

        user = api_helper.create_ai_agent
        if current_tenant.feature_enabled?("stripe_billing") && current_user.stripe_customer
          user.update!(stripe_customer_id: current_user.stripe_customer.id)
          StripeService.sync_subscription_quantity!(current_user)
        end
        token = api_helper.generate_token(user) if params[:generate_token]
        response = user.api_json
        response[:token] = token.plaintext_token if token
        render json: response
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: 400
      end
    end

    def update
      # Users can only update their own records or AI agent users
      user = current_tenant.users.find_by(id: params[:id])
      return render json: { error: 'User not found' }, status: 404 unless user
      return render json: { error: 'Unauthorized' }, status: 401 unless current_user.can_edit?(user)
      updatable_attributes.each do |attribute|
        # Use public_send since display_name/handle are delegated to tenant_user
        user.public_send("#{attribute}=", params[attribute]) if params.has_key?(attribute)
      end
      if params[:archived] == true && current_user != user
        user.archive!
      elsif params[:archived] == false && current_user != user
        user.unarchive!
      end
      # Save user if changed, and always save tenant_user since display_name/handle are stored there
      user.save! if user.changed?
      user.save_tenant_user! if user.tenant_user&.changed?

      # Sync billing after archive/unarchive
      if (params[:archived] == true || params[:archived] == false) &&
         user.ai_agent? && current_tenant.feature_enabled?("stripe_billing") && user.parent_id.present?
        parent = User.find_by(id: user.parent_id)
        StripeService.sync_subscription_quantity!(parent) if parent
      end

      render json: user.api_json
    end

    def destroy
      # Users can only delete AI agent users with no associated data
      user = current_tenant.users.find_by(id: params[:id])
      return render json: { error: 'User not found' }, status: 404 unless user
      return render json: { error: 'Unauthorized' }, status: 401 unless current_user.can_edit?(user)

      parent_id = user.parent_id
      is_agent = user.ai_agent?
      destroyed = false

      ActiveRecord::Base.transaction do
        user.tenant_user.destroy!
        ApiToken.where(user: user).destroy_all
        user.destroy!
        destroyed = true
        render json: { message: 'User deleted' }
      rescue ActiveRecord::InvalidForeignKey => e
        render json: { error: 'This user has associated data and cannot be deleted, but you can archive this user via PUT /api/v1/users/:user_id { "archived": true }' }, status: 400
      end

      # Sync billing only after successful deletion
      if destroyed && is_agent && current_tenant.feature_enabled?("stripe_billing") && parent_id.present?
        parent = User.find_by(id: parent_id)
        StripeService.sync_subscription_quantity!(parent) if parent
      end
    end

    private

    def updatable_attributes
      # Cannot update email because we derive from oauth provider
      [:display_name, :handle] # How to update pins?
    end
  end
end
