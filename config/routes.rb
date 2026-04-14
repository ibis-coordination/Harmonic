Rails.application.routes.draw do
  get 'healthcheck' => 'healthcheck#healthcheck'
  get 'metrics' => 'metrics#show'

  # Incoming webhooks - public endpoint for external automation triggers
  post 'hooks/:webhook_path' => 'incoming_webhooks#receive', as: 'incoming_webhook'

  # Stripe webhooks
  post 'stripe/webhooks' => 'stripe_webhooks#receive'

  # Billing management
  get 'billing' => 'billing#show', as: 'billing_show'
  post 'billing/setup' => 'billing#setup', as: 'billing_setup'
  get 'billing/portal' => 'billing#portal', as: 'billing_portal'
  post 'billing/deactivate_agent/:handle' => 'billing#deactivate_agent', as: 'billing_deactivate_agent'
  post 'billing/reactivate_agent/:handle' => 'billing#reactivate_agent', as: 'billing_reactivate_agent'
  post 'billing/deactivate_collective/:collective_handle' => 'billing#deactivate_collective', as: 'billing_deactivate_collective'
  post 'billing/reactivate_collective/:collective_handle' => 'billing#reactivate_collective', as: 'billing_reactivate_collective'
  post 'billing/topup' => 'billing#topup', as: 'billing_topup'

  # Development tools - Pulse styleguide (only available in development)
  if Rails.env.development?
    get 'dev/pulse' => 'dev#pulse_components'
  end

  # AI Agents management - consolidated under /ai-agents
  get 'ai-agents' => 'ai_agents#index', as: 'ai_agents'
  get 'ai-agents/new' => 'ai_agents#new', as: 'new_ai_agent'
  get 'ai-agents/new/actions' => 'ai_agents#actions_index', as: 'ai_agent_new_actions'
  get 'ai-agents/new/actions/create_ai_agent' => 'ai_agents#describe_create_ai_agent'
  post 'ai-agents/new/actions/create_ai_agent' => 'ai_agents#execute_create_ai_agent'
  get 'ai-agents/:handle' => 'ai_agents#show', as: 'ai_agent'
  get 'ai-agents/:handle/settings' => 'ai_agents#settings', as: 'ai_agent_settings'
  post 'ai-agents/:handle/settings' => 'ai_agents#update_settings'
  get 'ai-agents/:handle/settings/actions' => 'ai_agents#settings_actions_index'
  get 'ai-agents/:handle/settings/actions/update_ai_agent' => 'ai_agents#describe_update_ai_agent'
  post 'ai-agents/:handle/settings/actions/update_ai_agent' => 'ai_agents#execute_update_ai_agent'
  get 'ai-agents/:handle/run' => 'ai_agents#run_task', as: 'ai_agent_run_task'
  post 'ai-agents/:handle/run' => 'ai_agents#execute_task', as: 'ai_agent_execute_task'
  get 'ai-agents/:handle/runs' => 'ai_agents#runs', as: 'ai_agent_runs'
  get 'ai-agents/:handle/runs/:run_id' => 'ai_agents#show_run', as: 'ai_agent_run'
  post 'ai-agents/:handle/runs/:run_id/cancel' => 'ai_agents#cancel_run', as: 'cancel_ai_agent_run'
  # AI Agent automations
  get 'ai-agents/:handle/automations' => 'agent_automations#index', as: 'ai_agent_automations'
  get 'ai-agents/:handle/automations/new' => 'agent_automations#new', as: 'new_ai_agent_automation'
  get 'ai-agents/:handle/automations/new/actions' => 'agent_automations#actions_index_new'
  get 'ai-agents/:handle/automations/new/actions/create_automation_rule' => 'agent_automations#describe_create'
  post 'ai-agents/:handle/automations/new/actions/create_automation_rule' => 'agent_automations#execute_create'
  get 'ai-agents/:handle/automations/templates' => 'agent_automations#templates', as: 'ai_agent_automation_templates'
  get 'ai-agents/:handle/automations/:automation_id' => 'agent_automations#show', as: 'ai_agent_automation'
  get 'ai-agents/:handle/automations/:automation_id/edit' => 'agent_automations#edit', as: 'edit_ai_agent_automation'
  get 'ai-agents/:handle/automations/:automation_id/runs' => 'agent_automations#runs', as: 'ai_agent_automation_runs'
  get 'ai-agents/:handle/automations/:automation_id/actions' => 'agent_automations#actions_index_show'
  get 'ai-agents/:handle/automations/:automation_id/actions/update_automation_rule' => 'agent_automations#describe_update'
  post 'ai-agents/:handle/automations/:automation_id/actions/update_automation_rule' => 'agent_automations#execute_update'
  get 'ai-agents/:handle/automations/:automation_id/actions/delete_automation_rule' => 'agent_automations#describe_delete'
  post 'ai-agents/:handle/automations/:automation_id/actions/delete_automation_rule' => 'agent_automations#execute_delete'
  get 'ai-agents/:handle/automations/:automation_id/actions/toggle_automation_rule' => 'agent_automations#describe_toggle'
  post 'ai-agents/:handle/automations/:automation_id/actions/toggle_automation_rule' => 'agent_automations#execute_toggle'
  get 'ai-agents/:handle/automations/:automation_id/edit/actions' => 'agent_automations#actions_index_edit'

  if ENV['AUTH_MODE'] == 'honor_system'
    get 'login' => 'honor_system_sessions#new'
    post 'login' => 'honor_system_sessions#create'
    delete 'logout' => 'honor_system_sessions#destroy'
    get 'logout-success' => 'honor_system_sessions#logout_success'
  elsif ENV['AUTH_MODE'] == 'oauth'
    get 'login' => 'sessions#new'
    get 'auth/:provider/callback' => 'sessions#oauth_callback'
    post 'auth/:provider/callback' => 'sessions#oauth_callback'
    get  'auth/failure' => 'sessions#oauth_failure'
    get 'login/return' => 'sessions#return'
    get 'login/callback' => 'sessions#internal_callback'
    delete '/logout' => 'sessions#destroy'
    get 'logout-success' => 'sessions#logout_success'

    # Password reset routes
    resources :password_resets, only: [:new, :create], path: 'password'
    get 'password/reset/:token', to: 'password_resets#show', as: 'password_reset'
    patch 'password/reset/:token', to: 'password_resets#update'

    # Two-factor authentication routes
    get 'login/verify-2fa' => 'two_factor_auth#verify', as: 'two_factor_verify'
    post 'login/verify-2fa' => 'two_factor_auth#verify_submit'
    get 'settings/two-factor' => 'two_factor_auth#setup', as: 'two_factor_setup'
    post 'settings/two-factor/confirm' => 'two_factor_auth#confirm_setup', as: 'two_factor_confirm'
    get 'settings/two-factor/manage' => 'two_factor_auth#settings', as: 'two_factor_settings'
    post 'settings/two-factor/disable' => 'two_factor_auth#disable', as: 'two_factor_disable'
    post 'settings/two-factor/regenerate-codes' => 'two_factor_auth#regenerate_codes', as: 'two_factor_regenerate_codes'
  else
    raise 'Invalid AUTH_MODE'
  end

  namespace :api do
    namespace :v1 do
      get '/', to: 'info#index'
      resources :notes do
        post :confirm, to: 'note#confirm'
      end
      resources :decisions do
        get :results, to: 'results#index'
        resources :participants do
          resources :votes
        end
        resources :options do
          resources :votes
        end
        resources :votes
      end
      resources :commitments do
        post :join, to: 'commitments#join'
        resources :participants
      end
      resources :cycles
      resources :users do
        resources :api_tokens, path: 'tokens'
      end
    end

    # Admin API for cross-tenant management (used by Harmonic Admin App)
    namespace :app_admin do
      resources :tenants, only: [:index, :create, :show, :update, :destroy] do
        member do
          post :suspend
          post :activate
        end
      end
    end
  end
  # Defines the root path route ("/")
  root 'home#index'
  get '404' => 'home#page_not_found'
  get 'home' => 'home#index'
  get 'actions' => 'home#actions_index'
  # Redirect /settings to user-specific settings path
  get 'settings' => 'users#redirect_to_settings'

  get 'about' => 'home#about'
  get 'help' => 'home#help'
  get 'contact' => 'home#contact'
  get 'subdomains' => 'home#subdomains'

  # LLM Chat - Trio (with voting ensemble)
  get 'trio' => 'trio#index'
  post 'trio' => 'trio#create'

  # Notifications
  get 'notifications' => 'notifications#index'
  get 'notifications/new' => 'notifications#new'
  get 'notifications/unread_count' => 'notifications#unread_count'
  get 'notifications/actions' => 'notifications#actions_index'
  get 'notifications/actions/dismiss' => 'notifications#describe_dismiss'
  post 'notifications/actions/dismiss' => 'notifications#execute_dismiss'
  get 'notifications/actions/dismiss_all' => 'notifications#describe_dismiss_all'
  post 'notifications/actions/dismiss_all' => 'notifications#execute_dismiss_all'
  get 'notifications/actions/dismiss_for_collective' => 'notifications#describe_dismiss_for_collective'
  post 'notifications/actions/dismiss_for_collective' => 'notifications#execute_dismiss_for_collective'
  get 'notifications/actions/create_reminder' => 'notifications#describe_create_reminder'
  post 'notifications/actions/create_reminder' => 'notifications#execute_create_reminder'
  get 'notifications/actions/delete_reminder' => 'notifications#describe_delete_reminder'
  post 'notifications/actions/delete_reminder' => 'notifications#execute_delete_reminder'

  get 'learn' => 'learn#index'
  get 'learn/awareness-indicators' => 'learn#awareness_indicators'
  get 'learn/acceptance-voting' => 'learn#acceptance_voting'
  get 'learn/reciprocal-commitment' => 'learn#reciprocal_commitment'
  get 'learn/ai-agency' => 'learn#ai_agency'
  get 'learn/superagency' => 'learn#superagency'
  get 'learn/memory' => 'learn#memory'

  get 'whoami' => 'whoami#index'
  get 'whoami/actions' => 'whoami#actions_index'
  get 'whoami/actions/update_scratchpad' => 'whoami#describe_update_scratchpad'
  post 'whoami/actions/update_scratchpad' => 'whoami#execute_update_scratchpad'
  get 'motto' => 'motto#index'

  # Global search (tenant-level, searches across all accessible collectives)
  get 'search' => 'search#show'
  get 'search/actions' => 'search#actions_index'
  get 'search/actions/search' => 'search#describe_search'
  post 'search/actions/search' => 'search#execute_search'

  # ============================================================
  # ADMIN ROUTES
  # ============================================================

  # System Admin (primary tenant only, sys_admin role on User)
  # For system-level operations: Sidekiq, monitoring, etc.
  get 'system-admin' => 'system_admin#dashboard'
  get 'system-admin/sidekiq' => 'system_admin#sidekiq'
  get 'system-admin/sidekiq/queues/:name' => 'system_admin#sidekiq_show_queue'
  get 'system-admin/sidekiq/jobs/:jid' => 'system_admin#sidekiq_show_job'
  post 'system-admin/sidekiq/jobs/:jid/retry' => 'system_admin#sidekiq_retry_job'
  get 'system-admin/sidekiq/jobs/:jid/actions' => 'system_admin#sidekiq_job_actions_index'
  get 'system-admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job' => 'system_admin#describe_retry_sidekiq_job'
  post 'system-admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job' => 'system_admin#execute_retry_sidekiq_job'

  # App Admin (primary tenant only, app_admin role on User)
  # For cross-tenant management: tenants, users across all tenants
  get 'app-admin' => 'app_admin#dashboard'
  get 'app-admin/tenants' => 'app_admin#tenants'
  get 'app-admin/tenants/new' => 'app_admin#new_tenant'
  post 'app-admin/tenants' => 'app_admin#create_tenant'
  get 'app-admin/tenants/new/actions' => 'app_admin#actions_index_new_tenant'
  get 'app-admin/tenants/new/actions/create_tenant' => 'app_admin#describe_create_tenant'
  post 'app-admin/tenants/new/actions/create_tenant' => 'app_admin#execute_create_tenant'
  get 'app-admin/tenants/:subdomain/complete' => 'app_admin#complete_tenant_creation'
  get 'app-admin/tenants/:subdomain' => 'app_admin#show_tenant'
  get 'app-admin/users' => 'app_admin#users'
  get 'app-admin/users/:id' => 'app_admin#show_user', as: 'app_admin_user'
  get 'app-admin/users/:id/actions' => 'app_admin#actions_index_user'
  get 'app-admin/users/:id/actions/suspend_user' => 'app_admin#describe_suspend_user'
  post 'app-admin/users/:id/actions/suspend_user' => 'app_admin#execute_suspend_user'
  get 'app-admin/users/:id/actions/unsuspend_user' => 'app_admin#describe_unsuspend_user'
  post 'app-admin/users/:id/actions/unsuspend_user' => 'app_admin#execute_unsuspend_user'
  get 'app-admin/users/:id/actions/toggle_billing_exempt' => 'app_admin#describe_toggle_billing_exempt'
  post 'app-admin/users/:id/actions/toggle_billing_exempt' => 'app_admin#execute_toggle_billing_exempt'
  get 'app-admin/security' => 'app_admin#security_dashboard'
  get 'app-admin/security/events/:line_number' => 'app_admin#security_event'

  # Tenant Admin (any tenant, admin role on TenantUser)
  # For single-tenant management: settings, users
  get 'tenant-admin' => 'tenant_admin#dashboard'
  get 'tenant-admin/actions' => 'tenant_admin#actions_index'
  get 'tenant-admin/settings' => 'tenant_admin#settings'
  post 'tenant-admin/settings' => 'tenant_admin#update_settings'
  get 'tenant-admin/settings/actions' => 'tenant_admin#actions_index_settings'
  get 'tenant-admin/settings/actions/update_tenant_settings' => 'tenant_admin#describe_update_settings'
  post 'tenant-admin/settings/actions/update_tenant_settings' => 'tenant_admin#execute_update_settings'
  get 'tenant-admin/users' => 'tenant_admin#users'
  get 'tenant-admin/users/:handle' => 'tenant_admin#show_user', as: 'tenant_admin_user'
  # Note: Tenant admins do NOT have suspend/unsuspend actions - only app admins can suspend users

  # ============================================================
  # Admin Chooser (smart redirect based on user's admin roles)
  # ============================================================

  get 'admin' => 'admin_chooser#index'

  resources :users, path: 'u', param: :handle, only: [:show] do
    get 'settings', on: :member
    post 'settings/profile' => 'users#update_profile', on: :member
    patch 'image' => 'users#update_image', on: :member
    resources :api_tokens,
              path: 'settings/tokens',
              only: [:new, :create, :show, :destroy]
    # Representation routes
    post 'represent' => 'users#represent', on: :member
    delete 'represent' => 'users#stop_representing', on: :member
    post 'add_to_collective' => 'users#add_ai_agent_to_collective', on: :member
    delete 'remove_from_collective' => 'users#remove_ai_agent_from_collective', on: :member
    # User settings actions
    get 'settings/actions' => 'users#actions_index', on: :member
    get 'settings/actions/update_profile' => 'users#describe_update_profile', on: :member
    post 'settings/actions/update_profile' => 'users#execute_update_profile', on: :member
    # API token actions
    get 'settings/tokens/new/actions' => 'api_tokens#actions_index', on: :member
    get 'settings/tokens/new/actions/create_api_token' => 'api_tokens#describe_create_api_token', on: :member
    post 'settings/tokens/new/actions/create_api_token' => 'api_tokens#execute_create_api_token', on: :member
    # Trustee grant management (TrusteeGrants)
    get 'settings/trustee-grants' => 'trustee_grants#index', on: :member
    get 'settings/trustee-grants/actions' => 'trustee_grants#actions_index', on: :member
    get 'settings/trustee-grants/new' => 'trustee_grants#new', on: :member
    get 'settings/trustee-grants/new/actions' => 'trustee_grants#actions_index_new', on: :member
    get 'settings/trustee-grants/new/actions/create_trustee_grant' => 'trustee_grants#describe_create', on: :member
    post 'settings/trustee-grants/new/actions/create_trustee_grant' => 'trustee_grants#execute_create', on: :member
    get 'settings/trustee-grants/:grant_id' => 'trustee_grants#show', on: :member
    get 'settings/trustee-grants/:grant_id/actions' => 'trustee_grants#actions_index_show', on: :member
    get 'settings/trustee-grants/:grant_id/actions/accept_trustee_grant' => 'trustee_grants#describe_accept', on: :member
    post 'settings/trustee-grants/:grant_id/actions/accept_trustee_grant' => 'trustee_grants#execute_accept', on: :member
    get 'settings/trustee-grants/:grant_id/actions/decline_trustee_grant' => 'trustee_grants#describe_decline', on: :member
    post 'settings/trustee-grants/:grant_id/actions/decline_trustee_grant' => 'trustee_grants#execute_decline', on: :member
    get 'settings/trustee-grants/:grant_id/actions/revoke_trustee_grant' => 'trustee_grants#describe_revoke', on: :member
    post 'settings/trustee-grants/:grant_id/actions/revoke_trustee_grant' => 'trustee_grants#execute_revoke', on: :member
    get 'settings/trustee-grants/:grant_id/actions/start_representation' => 'trustee_grants#describe_start_representation', on: :member
    post 'settings/trustee-grants/:grant_id/actions/start_representation' => 'trustee_grants#execute_start_representation', on: :member
    get 'settings/trustee-grants/:grant_id/actions/end_representation' => 'trustee_grants#describe_end_representation', on: :member
    post 'settings/trustee-grants/:grant_id/actions/end_representation' => 'trustee_grants#execute_end_representation', on: :member
    post 'settings/trustee-grants/:grant_id/represent' => 'trustee_grants#start_representing', on: :member
  end

  # Representation session routes (not scoped to a specific collective)
  get '/representing' => 'representation_sessions#representing'
  delete '/representing' => 'representation_sessions#stop_representing_user'

  # Collective routes
  get "collectives" => "collectives#index"
  get "collectives/actions" => "collectives#actions_index"
  get "collectives/new" => "collectives#new"
  get "collectives/new/actions" => 'collectives#actions_index_new'
  get "collectives/new/actions/create_collective" => 'collectives#describe_create_collective'
  post "collectives/new/actions/create_collective" => 'collectives#create_collective'
  get "collectives/available" => 'collectives#handle_available'
  post "collectives" => "collectives#create"
  get "collectives/:collective_handle" => 'pulse#show'
  get "collectives/:collective_handle/actions" => 'pulse#actions_index'
  get "collectives/:collective_handle/actions/send_heartbeat" => 'collectives#describe_send_heartbeat'
  post "collectives/:collective_handle/actions/send_heartbeat" => 'collectives#send_heartbeat'
  get "collectives/:collective_handle/pinned.html" => 'collectives#pinned_items_partial'
  get "collectives/:collective_handle/members.html" => 'collectives#members_partial'
  get "collectives/:collective_handle/cycles" => 'cycles#index'
  get "collectives/:collective_handle/cycles/actions" => 'cycles#actions_index_default'
  get "collectives/:collective_handle/cycles/:cycle" => 'cycles#show'
  get "collectives/:collective_handle/cycle/:cycle" => 'cycles#redirect_to_show'
  get "collectives/:collective_handle/classic" => 'collectives#show'
  get "collectives/:collective_handle/views" => 'collectives#views'
  get "collectives/:collective_handle/view" => 'collectives#view'
  get "collectives/:collective_handle/members" => 'collectives#members'
  get "collectives/:collective_handle/settings" => 'collectives#settings'
  post "collectives/:collective_handle/settings" => 'collectives#update_settings'
  post "collectives/:collective_handle/settings/add_ai_agent" => 'collectives#add_ai_agent'
  delete "collectives/:collective_handle/settings/remove_ai_agent" => 'collectives#remove_ai_agent'
  get "collectives/:collective_handle/settings/actions" => 'collectives#actions_index_settings'
  get "collectives/:collective_handle/settings/actions/update_collective_settings" => 'collectives#describe_update_collective_settings'
  post "collectives/:collective_handle/settings/actions/update_collective_settings" => 'collectives#update_collective_settings_action'
  get "collectives/:collective_handle/settings/actions/add_ai_agent_to_collective" => 'collectives#describe_add_ai_agent_to_collective'
  post "collectives/:collective_handle/settings/actions/add_ai_agent_to_collective" => 'collectives#execute_add_ai_agent_to_collective'
  get "collectives/:collective_handle/settings/actions/remove_ai_agent_from_collective" => 'collectives#describe_remove_ai_agent_from_collective'
  post "collectives/:collective_handle/settings/actions/remove_ai_agent_from_collective" => 'collectives#execute_remove_ai_agent_from_collective'
  # Collective Automations
  get "collectives/:collective_handle/settings/automations" => 'collective_automations#index'
  get "collectives/:collective_handle/settings/automations/new" => 'collective_automations#new'
  get "collectives/:collective_handle/settings/automations/new/actions" => 'collective_automations#actions_index_new'
  get "collectives/:collective_handle/settings/automations/new/actions/create_automation_rule" => 'collective_automations#describe_create'
  post "collectives/:collective_handle/settings/automations/new/actions/create_automation_rule" => 'collective_automations#execute_create'
  get "collectives/:collective_handle/settings/automations/:automation_id" => 'collective_automations#show'
  get "collectives/:collective_handle/settings/automations/:automation_id/edit" => 'collective_automations#edit'
  get "collectives/:collective_handle/settings/automations/:automation_id/runs" => 'collective_automations#runs'
  get "collectives/:collective_handle/settings/automations/:automation_id/runs/:run_id" => 'collective_automations#run_show'
  get "collectives/:collective_handle/settings/automations/:automation_id/actions" => 'collective_automations#actions_index_show'
  get "collectives/:collective_handle/settings/automations/:automation_id/actions/update_automation_rule" => 'collective_automations#describe_update'
  post "collectives/:collective_handle/settings/automations/:automation_id/actions/update_automation_rule" => 'collective_automations#execute_update'
  get "collectives/:collective_handle/settings/automations/:automation_id/actions/delete_automation_rule" => 'collective_automations#describe_delete'
  post "collectives/:collective_handle/settings/automations/:automation_id/actions/delete_automation_rule" => 'collective_automations#execute_delete'
  get "collectives/:collective_handle/settings/automations/:automation_id/actions/toggle_automation_rule" => 'collective_automations#describe_toggle'
  post "collectives/:collective_handle/settings/automations/:automation_id/actions/toggle_automation_rule" => 'collective_automations#execute_toggle'
  get "collectives/:collective_handle/settings/automations/:automation_id/actions/test_automation_rule" => 'collective_automations#describe_test'
  post "collectives/:collective_handle/settings/automations/:automation_id/actions/test_automation_rule" => 'collective_automations#execute_test'
  get "collectives/:collective_handle/settings/automations/:automation_id/actions/run_automation_rule" => 'collective_automations#describe_run'
  post "collectives/:collective_handle/settings/automations/:automation_id/actions/run_automation_rule" => 'collective_automations#execute_run'
  get "collectives/:collective_handle/settings/automations/:automation_id/edit/actions" => 'collective_automations#actions_index_edit'
  patch "collectives/:collective_handle/image" => 'collectives#update_image'
  get "collectives/:collective_handle/invite" => 'collectives#invite'
  get "collectives/:collective_handle/join" => 'collectives#join'
  post "collectives/:collective_handle/join" => 'collectives#accept_invite'
  get "collectives/:collective_handle/join/actions" => 'collectives#actions_index_join'
  get "collectives/:collective_handle/join/actions/join_collective" => 'collectives#describe_join_collective'
  post "collectives/:collective_handle/join/actions/join_collective" => 'collectives#join_collective_action'
  get "collectives/:collective_handle/represent" => 'representation_sessions#represent'
  post "collectives/:collective_handle/represent" => 'representation_sessions#start_representing'
  post "collectives/:collective_handle/represent_user" => 'representation_sessions#start_representing_user'
  delete "collectives/:collective_handle/represent" => 'representation_sessions#stop_representing'
  delete "collectives/:collective_handle/r/:representation_session_id" => 'representation_sessions#stop_representing'
  get "collectives/:collective_handle/representation.html" => 'representation_sessions#index_partial'
  get "collectives/:collective_handle/representation" => 'representation_sessions#index'
  get "collectives/:collective_handle/r/:id" => 'representation_sessions#show'
  post "collectives/:collective_handle/r/:representation_session_id/comments" => 'representation_sessions#create_comment'
  get "collectives/:collective_handle/r/:representation_session_id/comments.html" => 'representation_sessions#comments_partial'
  get "collectives/:collective_handle/u/:handle" => 'users#show'
  # Autocomplete endpoints (scoped to collective members)
  get "collectives/:collective_handle/autocomplete/users" => 'autocomplete#users'
  get "collectives/:collective_handle/backlinks" => 'collectives#backlinks'
  get "collectives/:collective_handle/backlinks/actions" => 'collectives#actions_index_default'
  get "collectives/:collective_handle/heartbeats" => 'heartbeats#index'
  post "collectives/:collective_handle/heartbeats" => 'heartbeats#create'
  get "collectives/:collective_handle/heartbeats/actions" => 'heartbeats#actions_index_default'
  post "collectives/:collective_handle/heartbeats/actions/create_heartbeat" => 'heartbeats#create_heartbeat'

  ['', 'collectives/:collective_handle'].each do |prefix|
    get "#{prefix}/note" => 'notes#new'
    post "#{prefix}/note" => 'notes#create'
    get "#{prefix}/note/actions" => 'notes#actions_index_new'
    get "#{prefix}/note/actions/create_note" => 'notes#describe_create_note'
    post "#{prefix}/note/actions/create_note" => 'notes#create_note'
    resources :notes, only: [:show], path: "#{prefix}/n" do
      get '/actions' => 'notes#actions_index_show'
      get '/actions/confirm_read' => 'notes#describe_confirm_read'
      post '/actions/confirm_read' => 'notes#confirm_read'
      get '/actions/add_comment' => 'notes#describe_add_comment'
      post '/actions/add_comment' => 'notes#add_comment'
      post '/comments' => 'notes#create_comment'
      get '/comments.html' => 'notes#comments_partial'
      get '/edit/actions' => 'notes#actions_index_edit'
      get '/edit/actions/update_note' => 'notes#describe_update_note'
      post '/edit/actions/update_note' => 'notes#update_note'
      get '/edit/actions/add_attachment' => 'notes#describe_add_attachment'
      post '/edit/actions/add_attachment' => 'notes#add_attachment'
      get '/metric' => 'notes#metric'
      get '/edit' => 'notes#edit'
      post '/edit' => 'notes#update'
      get '/history.html' => 'notes#history_log_partial'
      post '/confirm.html' => 'notes#confirm_and_return_partial'
      put '/pin' => 'notes#pin'
      get '/attachments/:attachment_id' => 'attachments#show'
      get '/attachments/:attachment_id/actions' => 'notes#actions_index_attachment'
      get '/attachments/:attachment_id/actions/remove_attachment' => 'notes#describe_remove_attachment'
      post '/attachments/:attachment_id/actions/remove_attachment' => 'notes#remove_attachment'
      get '/settings' => 'notes#settings'
      get '/settings/actions' => 'notes#actions_index_settings'
      get '/settings/actions/pin_note' => 'notes#describe_pin_note'
      post '/settings/actions/pin_note' => 'notes#pin_note_action'
      get '/settings/actions/unpin_note' => 'notes#describe_unpin_note'
      post '/settings/actions/unpin_note' => 'notes#unpin_note_action'
    end

    get "#{prefix}/decide" => 'decisions#new'
    post "#{prefix}/decide" => 'decisions#create'
    get "#{prefix}/decide/actions" => 'decisions#actions_index_new'
    get "#{prefix}/decide/actions/create_decision" => 'decisions#describe_create_decision'
    post "#{prefix}/decide/actions/create_decision" => 'decisions#create_decision'
    resources :decisions, only: [:show], path: "#{prefix}/d" do
      get '/actions' => 'decisions#actions_index_show'
      get '/actions/add_options' => 'decisions#describe_add_options'
      post '/actions/add_options' => 'decisions#add_options'
      get '/actions/vote' => 'decisions#describe_vote'
      post '/actions/vote' => 'decisions#vote'
      get '/actions/add_comment' => 'decisions#describe_add_comment'
      post '/actions/add_comment' => 'decisions#add_comment'
      post '/comments' => 'decisions#create_comment'
      get '/comments.html' => 'decisions#comments_partial'
      get '/metric' => 'decisions#metric'
      get '/results.html' => 'decisions#results_partial'
      get '/options.html' => 'decisions#options_partial'
      post '/options.html' => 'decisions#create_option_and_return_options_partial'
      get '/voters.html' => 'decisions#voters_partial'
      put '/pin' => 'decisions#pin'
      get '/attachments/:attachment_id' => 'attachments#show'
      get '/attachments/:attachment_id/actions' => 'decisions#actions_index_attachment'
      get '/attachments/:attachment_id/actions/remove_attachment' => 'decisions#describe_remove_attachment'
      post '/attachments/:attachment_id/actions/remove_attachment' => 'decisions#remove_attachment'
      post '/duplicate' => 'decisions#duplicate'
      get '/settings' => 'decisions#settings'
      post '/settings' => 'decisions#update_settings'
      get '/settings/actions' => 'decisions#actions_index_settings'
      get '/settings/actions/update_decision_settings' => 'decisions#describe_update_decision_settings'
      post '/settings/actions/update_decision_settings' => 'decisions#update_decision_settings_action'
      get '/settings/actions/pin_decision' => 'decisions#describe_pin_decision'
      post '/settings/actions/pin_decision' => 'decisions#pin_decision_action'
      get '/settings/actions/unpin_decision' => 'decisions#describe_unpin_decision'
      post '/settings/actions/unpin_decision' => 'decisions#unpin_decision_action'
      get '/settings/actions/add_attachment' => 'decisions#describe_add_attachment'
      post '/settings/actions/add_attachment' => 'decisions#add_attachment'
    end

    get "#{prefix}/commit" => 'commitments#new'
    post "#{prefix}/commit" => 'commitments#create'
    get "#{prefix}/commit/actions" => 'commitments#actions_index_new'
    get "#{prefix}/commit/actions/create_commitment" => 'commitments#describe_create_commitment'
    post "#{prefix}/commit/actions/create_commitment" => 'commitments#create_commitment_action'
    resources :commitments, only: [:show], path: "#{prefix}/c" do
      get '/actions' => 'commitments#actions_index_show'
      get '/actions/join_commitment' => 'commitments#describe_join_commitment'
      post '/actions/join_commitment' => 'commitments#join_commitment'
      get '/actions/add_comment' => 'commitments#describe_add_comment'
      post '/actions/add_comment' => 'commitments#add_comment'
      get '/metric' => 'commitments#metric'
      get '/status.html' => 'commitments#status_partial'
      get '/participants.html' => 'commitments#participants_list_items_partial'
      post '/join.html' => 'commitments#join_and_return_partial'
      put '/pin' => 'commitments#pin'
      post '/comments' => 'commitments#create_comment'
      get '/comments.html' => 'commitments#comments_partial'
      get '/attachments/:attachment_id' => 'attachments#show'
      get '/attachments/:attachment_id/actions' => 'commitments#actions_index_attachment'
      get '/attachments/:attachment_id/actions/remove_attachment' => 'commitments#describe_remove_attachment'
      post '/attachments/:attachment_id/actions/remove_attachment' => 'commitments#remove_attachment'
      get '/settings' => 'commitments#settings'
      post '/settings' => 'commitments#update_settings'
      get '/settings/actions' => 'commitments#actions_index_settings'
      get '/settings/actions/update_commitment_settings' => 'commitments#describe_update_commitment_settings'
      post '/settings/actions/update_commitment_settings' => 'commitments#update_commitment_settings_action'
      get '/settings/actions/pin_commitment' => 'commitments#describe_pin_commitment'
      post '/settings/actions/pin_commitment' => 'commitments#pin_commitment_action'
      get '/settings/actions/unpin_commitment' => 'commitments#describe_unpin_commitment'
      post '/settings/actions/unpin_commitment' => 'commitments#unpin_commitment_action'
      get '/settings/actions/add_attachment' => 'commitments#describe_add_attachment'
      post '/settings/actions/add_attachment' => 'commitments#add_attachment'
    end

    namespace :api, path: "#{prefix}/api" do
      namespace :v1 do
        get '/', to: 'info#index'
        resources :notes do
          post :confirm, to: 'note#confirm'
        end
        resources :decisions do
          get :results, to: 'results#index'
          resources :participants do
            resources :votes
          end
          resources :options do
            resources :votes
          end
          resources :votes
        end
        resources :commitments do
          post :join, to: 'commitments#join'
          resources :participants
        end
        if prefix == 'collectives/:collective_handle'
          # Cycles must be scoped to a collective
          resources :cycles
        else
          # Collectives must not be scoped to a collective (doesn't make sense)
          resources :collectives
        end
      end
    end
  end
end
