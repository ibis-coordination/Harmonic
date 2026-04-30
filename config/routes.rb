Rails.application.routes.draw do
  get 'healthcheck' => 'healthcheck#healthcheck'
  get 'metrics' => 'metrics#show'

  # Internal API for agent-runner service (IP-restricted + HMAC-signed)
  scope "internal/agent-runner", module: "internal", as: "internal_agent_runner" do
    post 'tasks/:id/claim' => 'agent_runner#claim'
    post 'tasks/:id/step' => 'agent_runner#step'
    post 'tasks/:id/complete' => 'agent_runner#complete'
    post 'tasks/:id/fail' => 'agent_runner#fail_task'
    put  'tasks/:id/scratchpad' => 'agent_runner#scratchpad'
    get  'tasks/:id/status' => 'agent_runner#status'
    post 'tasks/:id/preflight' => 'agent_runner#preflight'
    get  'chat/:chat_session_id/history' => 'agent_runner#chat_history'
  end

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

  # Development tools - styleguide (only available in development)
  if Rails.env.development?
    get "dev/styleguide" => "dev#styleguide"
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
  # AI Agent chat
  get  'ai-agents/:handle/chat'                        => 'ai_agent_chats#index', as: 'ai_agent_chats'
  post 'ai-agents/:handle/chat'                        => 'ai_agent_chats#create', as: 'ai_agent_chat_create'
  get  'ai-agents/:handle/chat/:session_id'            => 'ai_agent_chats#show', as: 'ai_agent_chat'
  post 'ai-agents/:handle/chat/:session_id/message'    => 'ai_agent_chats#send_message', as: 'ai_agent_chat_message'
  get  'ai-agents/:handle/chat/:session_id/messages'   => 'ai_agent_chats#poll_messages', as: 'ai_agent_chat_poll'

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
  get 'help' => 'help#index'
  %w[privacy collectives notes reminder-notes table-notes decisions commitments cycles search links agents api].each do |topic|
    get "help/#{topic}" => "help##{topic.underscore}"
  end
  get 'contact' => 'home#contact'
  get 'subdomains' => 'home#subdomains'

  # LLM Chat - Trio (with voting ensemble)
  get 'trio' => 'trio#index'
  post 'trio' => 'trio#create'

  # User blocks
  resources :user_blocks, only: [:index, :create, :destroy], path: "user-blocks"

  # Notifications
  get 'notifications' => 'notifications#index'
  get 'notifications/unread_count' => 'notifications#unread_count'
  get 'notifications/actions' => 'notifications#actions_index'
  get 'notifications/actions/dismiss' => 'notifications#describe_dismiss'
  post 'notifications/actions/dismiss' => 'notifications#execute_dismiss'
  get 'notifications/actions/dismiss_all' => 'notifications#describe_dismiss_all'
  post 'notifications/actions/dismiss_all' => 'notifications#execute_dismiss_all'
  get 'notifications/actions/dismiss_for_collective' => 'notifications#describe_dismiss_for_collective'
  post 'notifications/actions/dismiss_for_collective' => 'notifications#execute_dismiss_for_collective'

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
  get 'reverify' => 'reverification#show', as: 'reverify'
  post 'reverify' => 'reverification#verify'
  get 'reverify/replay' => 'reverification#replay', as: 'reverify_replay'

  get 'system-admin' => 'system_admin#dashboard'
  get 'system-admin/sidekiq' => 'system_admin#sidekiq'
  get 'system-admin/sidekiq/queues/:name' => 'system_admin#sidekiq_show_queue'
  get 'system-admin/sidekiq/jobs/:jid' => 'system_admin#sidekiq_show_job'
  post 'system-admin/sidekiq/jobs/:jid/retry' => 'system_admin#sidekiq_retry_job'
  get 'system-admin/sidekiq/jobs/:jid/actions' => 'system_admin#sidekiq_job_actions_index'
  get 'system-admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job' => 'system_admin#describe_retry_sidekiq_job'
  post 'system-admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job' => 'system_admin#execute_retry_sidekiq_job'
  get 'system-admin/agent-runner' => 'system_admin#agent_runner'
  get 'system-admin/agent-runner/runs/:id' => 'system_admin#show_task_run', as: 'system_admin_task_run'

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
  post 'app-admin/users/:id/actions/account_security_reset' => 'app_admin#execute_account_security_reset'
  get 'app-admin/reports' => 'app_admin#reports'
  get 'app-admin/reports/:id' => 'app_admin#show_report', as: 'app_admin_report'
  post 'app-admin/reports/:id/review' => 'app_admin#execute_review_report'
  post 'app-admin/reports/:id/delete-content' => 'app_admin#execute_delete_reported_content'
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
    patch 'settings/email' => 'users#update_email', on: :member
    delete 'settings/email' => 'users#cancel_email_change', on: :member
    get 'settings/email/confirm/:token' => 'users#confirm_email', on: :member, as: 'confirm_email'
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
  # Bare /workspace redirects to the current user's private workspace
  get "workspace" => "collectives#redirect_to_workspace"
  # Routes for collective-scoped pages. Both /collectives/ and /workspace/ prefixes map to
  # the same controllers — private workspaces use /workspace/ while standard collectives use /collectives/.
  ['collectives', 'workspace'].each do |scope_prefix|
    prefix = "#{scope_prefix}/:collective_handle"
    get "#{prefix}" => 'pulse#show'
    get "#{prefix}/actions" => 'pulse#actions_index'
    get "#{prefix}/actions/send_heartbeat" => 'collectives#describe_send_heartbeat'
    post "#{prefix}/actions/send_heartbeat" => 'collectives#send_heartbeat'
    get "#{prefix}/pinned.html" => 'collectives#pinned_items_partial'
    get "#{prefix}/members.html" => 'collectives#members_partial'
    get "#{prefix}/cycles" => 'cycles#index'
    get "#{prefix}/cycles/actions" => 'cycles#actions_index_default'
    get "#{prefix}/cycles/:cycle" => 'cycles#show'
    get "#{prefix}/cycle/:cycle" => 'cycles#redirect_to_show'
    get "#{prefix}/classic" => 'collectives#show'
    get "#{prefix}/views" => 'collectives#views'
    get "#{prefix}/view" => 'collectives#view'
    get "#{prefix}/members" => 'collectives#members'
    get "#{prefix}/settings" => 'collectives#settings'
    post "#{prefix}/settings" => 'collectives#update_settings'
    post "#{prefix}/settings/add_ai_agent" => 'collectives#add_ai_agent'
    delete "#{prefix}/settings/remove_ai_agent" => 'collectives#remove_ai_agent'
    get "#{prefix}/settings/actions" => 'collectives#actions_index_settings'
    get "#{prefix}/settings/actions/update_collective_settings" => 'collectives#describe_update_collective_settings'
    post "#{prefix}/settings/actions/update_collective_settings" => 'collectives#update_collective_settings_action'
    get "#{prefix}/settings/actions/add_ai_agent_to_collective" => 'collectives#describe_add_ai_agent_to_collective'
    post "#{prefix}/settings/actions/add_ai_agent_to_collective" => 'collectives#execute_add_ai_agent_to_collective'
    get "#{prefix}/settings/actions/remove_ai_agent_from_collective" => 'collectives#describe_remove_ai_agent_from_collective'
    post "#{prefix}/settings/actions/remove_ai_agent_from_collective" => 'collectives#execute_remove_ai_agent_from_collective'
    # Automations
    get "#{prefix}/settings/automations" => 'collective_automations#index'
    get "#{prefix}/settings/automations/new" => 'collective_automations#new'
    get "#{prefix}/settings/automations/new/actions" => 'collective_automations#actions_index_new'
    get "#{prefix}/settings/automations/new/actions/create_automation_rule" => 'collective_automations#describe_create'
    post "#{prefix}/settings/automations/new/actions/create_automation_rule" => 'collective_automations#execute_create'
    get "#{prefix}/settings/automations/:automation_id" => 'collective_automations#show'
    get "#{prefix}/settings/automations/:automation_id/edit" => 'collective_automations#edit'
    get "#{prefix}/settings/automations/:automation_id/runs" => 'collective_automations#runs'
    get "#{prefix}/settings/automations/:automation_id/runs/:run_id" => 'collective_automations#run_show'
    get "#{prefix}/settings/automations/:automation_id/actions" => 'collective_automations#actions_index_show'
    get "#{prefix}/settings/automations/:automation_id/actions/update_automation_rule" => 'collective_automations#describe_update'
    post "#{prefix}/settings/automations/:automation_id/actions/update_automation_rule" => 'collective_automations#execute_update'
    get "#{prefix}/settings/automations/:automation_id/actions/delete_automation_rule" => 'collective_automations#describe_delete'
    post "#{prefix}/settings/automations/:automation_id/actions/delete_automation_rule" => 'collective_automations#execute_delete'
    get "#{prefix}/settings/automations/:automation_id/actions/toggle_automation_rule" => 'collective_automations#describe_toggle'
    post "#{prefix}/settings/automations/:automation_id/actions/toggle_automation_rule" => 'collective_automations#execute_toggle'
    get "#{prefix}/settings/automations/:automation_id/actions/test_automation_rule" => 'collective_automations#describe_test'
    post "#{prefix}/settings/automations/:automation_id/actions/test_automation_rule" => 'collective_automations#execute_test'
    get "#{prefix}/settings/automations/:automation_id/actions/run_automation_rule" => 'collective_automations#describe_run'
    post "#{prefix}/settings/automations/:automation_id/actions/run_automation_rule" => 'collective_automations#execute_run'
    get "#{prefix}/settings/automations/:automation_id/edit/actions" => 'collective_automations#actions_index_edit'
    patch "#{prefix}/image" => 'collectives#update_image'
    get "#{prefix}/invite" => 'collectives#invite'
    get "#{prefix}/join" => 'collectives#join'
    post "#{prefix}/join" => 'collectives#accept_invite'
    get "#{prefix}/join/actions" => 'collectives#actions_index_join'
    get "#{prefix}/join/actions/join_collective" => 'collectives#describe_join_collective'
    post "#{prefix}/join/actions/join_collective" => 'collectives#join_collective_action'
    get "#{prefix}/represent" => 'representation_sessions#represent'
    post "#{prefix}/represent" => 'representation_sessions#start_representing'
    post "#{prefix}/represent_user" => 'representation_sessions#start_representing_user'
    delete "#{prefix}/represent" => 'representation_sessions#stop_representing'
    delete "#{prefix}/r/:representation_session_id" => 'representation_sessions#stop_representing'
    get "#{prefix}/representation.html" => 'representation_sessions#index_partial'
    get "#{prefix}/representation" => 'representation_sessions#index'
    get "#{prefix}/r/:id" => 'representation_sessions#show'
    post "#{prefix}/r/:representation_session_id/comments" => 'representation_sessions#create_comment'
    get "#{prefix}/r/:representation_session_id/comments.html" => 'representation_sessions#comments_partial'
    get "#{prefix}/u/:handle" => 'users#show'
    get "#{prefix}/autocomplete/users" => 'autocomplete#users'
    get "#{prefix}/backlinks" => 'collectives#backlinks'
    get "#{prefix}/backlinks/actions" => 'collectives#actions_index_default'
    get "#{prefix}/heartbeats" => 'heartbeats#index'
    post "#{prefix}/heartbeats" => 'heartbeats#create'
    get "#{prefix}/heartbeats/actions" => 'heartbeats#actions_index_default'
    post "#{prefix}/heartbeats/actions/create_heartbeat" => 'heartbeats#create_heartbeat'
  end

  ['', 'collectives/:collective_handle', 'workspace/:collective_handle'].each do |prefix|
    get "#{prefix}/note" => 'notes#new'
    post "#{prefix}/note" => 'notes#create'
    get "#{prefix}/note/actions" => 'notes#actions_index_new'
    get "#{prefix}/note/actions/create_note" => 'notes#describe_create_note'
    post "#{prefix}/note/actions/create_note" => 'notes#create_note'
    get "#{prefix}/note/actions/create_reminder_note" => 'notes#describe_create_reminder_note'
    post "#{prefix}/note/actions/create_reminder_note" => 'notes#create_reminder_note_action'
    get "#{prefix}/note/actions/create_table_note" => 'notes#describe_create_table_note'
    post "#{prefix}/note/actions/create_table_note" => 'notes#create_table_note_action'
    resources :notes, only: [:show], path: "#{prefix}/n" do
      get '/report' => 'notes#report'
      get '/actions' => 'notes#actions_index_show'
      get '/actions/confirm_read' => 'notes#describe_confirm_read'
      post '/actions/confirm_read' => 'notes#confirm_read'
      get '/actions/report_content' => 'notes#describe_report_content'
      post '/actions/report_content' => 'notes#report_content_action'
      # Reminder note actions
      get '/actions/cancel_reminder' => 'notes#describe_cancel_reminder'
      post '/actions/cancel_reminder' => 'notes#execute_cancel_reminder'
      get '/actions/acknowledge_reminder' => 'notes#describe_acknowledge_reminder'
      post '/actions/acknowledge_reminder' => 'notes#acknowledge_reminder'
      # Table note actions
      get '/actions/add_row' => 'notes#describe_add_row'
      post '/actions/add_row' => 'notes#execute_add_row'
      get '/actions/update_row' => 'notes#describe_update_row'
      post '/actions/update_row' => 'notes#execute_update_row'
      get '/actions/delete_row' => 'notes#describe_delete_row'
      post '/actions/delete_row' => 'notes#execute_delete_row'
      get '/actions/add_table_column' => 'notes#describe_add_table_column'
      post '/actions/add_table_column' => 'notes#execute_add_table_column'
      get '/actions/remove_table_column' => 'notes#describe_remove_table_column'
      post '/actions/remove_table_column' => 'notes#execute_remove_table_column'
      get '/actions/query_rows' => 'notes#describe_query_rows'
      post '/actions/query_rows' => 'notes#execute_query_rows'
      get '/actions/summarize' => 'notes#describe_summarize'
      post '/actions/summarize' => 'notes#execute_summarize'
      get '/actions/update_table_description' => 'notes#describe_update_table_description'
      post '/actions/update_table_description' => 'notes#execute_update_table_description'
      get '/actions/batch_table_update' => 'notes#describe_batch_table_update'
      post '/actions/batch_table_update' => 'notes#execute_batch_table_update'
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
      post '/acknowledge.html' => 'notes#acknowledge_and_return_partial'
      put '/pin' => 'notes#pin'
      get '/attachments/:attachment_id' => 'attachments#show'
      get '/attachments/:attachment_id/actions' => 'notes#actions_index_attachment'
      get '/attachments/:attachment_id/actions/remove_attachment' => 'notes#describe_remove_attachment'
      post '/attachments/:attachment_id/actions/remove_attachment' => 'notes#remove_attachment'
      get '/settings' => 'notes#settings'
      post '/settings' => 'notes#update_settings'
      get '/settings/actions' => 'notes#actions_index_settings'
      get '/settings/actions/pin_note' => 'notes#describe_pin_note'
      post '/settings/actions/pin_note' => 'notes#pin_note_action'
      get '/settings/actions/unpin_note' => 'notes#describe_unpin_note'
      post '/settings/actions/unpin_note' => 'notes#unpin_note_action'
      get '/settings/actions/delete_note' => 'notes#describe_delete_note'
      post '/settings/actions/delete_note' => 'notes#execute_delete_note'
    end

    get "#{prefix}/decide" => 'decisions#new'
    post "#{prefix}/decide" => 'decisions#create'
    get "#{prefix}/decide/actions" => 'decisions#actions_index_new'
    get "#{prefix}/decide/actions/create_decision" => 'decisions#describe_create_decision'
    post "#{prefix}/decide/actions/create_decision" => 'decisions#create_decision'
    resources :decisions, only: [:show], path: "#{prefix}/d" do
      get '/report' => 'decisions#report'
      get '/actions' => 'decisions#actions_index_show'
      get '/actions/add_options' => 'decisions#describe_add_options'
      post '/actions/add_options' => 'decisions#add_options'
      get '/actions/vote' => 'decisions#describe_vote'
      post '/actions/vote' => 'decisions#vote'
      get '/actions/add_comment' => 'decisions#describe_add_comment'
      post '/actions/add_comment' => 'decisions#add_comment'
      get '/actions/close_decision' => 'decisions#describe_close_decision'
      post '/actions/close_decision' => 'decisions#close_decision_action'
      get '/actions/report_content' => 'decisions#describe_report_content'
      post '/actions/report_content' => 'decisions#report_content_action'
      post '/comments' => 'decisions#create_comment'
      get '/comments.html' => 'decisions#comments_partial'
      get '/metric' => 'decisions#metric'
      get '/results.html' => 'decisions#results_partial'
      get '/options.html' => 'decisions#options_partial'
      post '/options.html' => 'decisions#create_option_and_return_options_partial'
      get '/voters' => 'decisions#voters_page'
      get '/voters.html' => 'decisions#voters_partial'
      put '/pin' => 'decisions#pin'
      get '/attachments/:attachment_id' => 'attachments#show'
      get '/attachments/:attachment_id/actions' => 'decisions#actions_index_attachment'
      get '/attachments/:attachment_id/actions/remove_attachment' => 'decisions#describe_remove_attachment'
      post '/attachments/:attachment_id/actions/remove_attachment' => 'decisions#remove_attachment'
      post '/submit_votes' => 'decisions#submit_votes'
      post '/final_statement' => 'decisions#update_final_statement'
      get '/actions/update_final_statement' => 'decisions#describe_update_final_statement'
      post '/actions/update_final_statement' => 'decisions#update_final_statement'
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
      get '/settings/actions/delete_decision' => 'decisions#describe_delete_decision'
      post '/settings/actions/delete_decision' => 'decisions#execute_delete_decision'
    end

    get "#{prefix}/commit" => 'commitments#new'
    post "#{prefix}/commit" => 'commitments#create'
    get "#{prefix}/commit/actions" => 'commitments#actions_index_new'
    get "#{prefix}/commit/actions/create_commitment" => 'commitments#describe_create_commitment'
    post "#{prefix}/commit/actions/create_commitment" => 'commitments#create_commitment_action'
    resources :commitments, only: [:show], path: "#{prefix}/c" do
      get '/report' => 'commitments#report'
      get '/actions' => 'commitments#actions_index_show'
      get '/actions/join_commitment' => 'commitments#describe_join_commitment'
      post '/actions/join_commitment' => 'commitments#join_commitment'
      get '/actions/add_comment' => 'commitments#describe_add_comment'
      post '/actions/add_comment' => 'commitments#add_comment'
      get '/actions/report_content' => 'commitments#describe_report_content'
      post '/actions/report_content' => 'commitments#report_content_action'
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
      get '/settings/actions/delete_commitment' => 'commitments#describe_delete_commitment'
      post '/settings/actions/delete_commitment' => 'commitments#execute_delete_commitment'
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
