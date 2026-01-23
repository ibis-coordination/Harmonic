Rails.application.routes.draw do
  get 'healthcheck' => 'healthcheck#healthcheck'

  if ENV['AUTH_MODE'] == 'honor_system'
    get 'login' => 'honor_system_sessions#new'
    post 'login' => 'honor_system_sessions#create'
    delete 'logout' => 'honor_system_sessions#destroy'
    get 'logout-success' => 'honor_system_sessions#logout_success'
  elsif ENV['AUTH_MODE'] == 'oauth'
    get 'login' => 'sessions#new'
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
  get 'settings/webhooks' => 'users#redirect_to_settings_webhooks'

  get 'about' => 'home#about'
  get 'help' => 'home#help'
  get 'contact' => 'home#contact'

  # LLM Chat - Trio (with voting ensemble)
  get 'trio' => 'trio#index'
  post 'trio' => 'trio#create'

  # Notifications
  get 'notifications' => 'notifications#index'
  get 'notifications/unread_count' => 'notifications#unread_count'
  get 'notifications/actions' => 'notifications#actions_index'
  get 'notifications/actions/mark_read' => 'notifications#describe_mark_read'
  post 'notifications/actions/mark_read' => 'notifications#execute_mark_read'
  get 'notifications/actions/dismiss' => 'notifications#describe_dismiss'
  post 'notifications/actions/dismiss' => 'notifications#execute_dismiss'
  get 'notifications/actions/mark_all_read' => 'notifications#describe_mark_all_read'
  post 'notifications/actions/mark_all_read' => 'notifications#execute_mark_all_read'
  get 'notifications/actions/create_reminder' => 'notifications#describe_create_reminder'
  post 'notifications/actions/create_reminder' => 'notifications#execute_create_reminder'
  get 'notifications/actions/delete_reminder' => 'notifications#describe_delete_reminder'
  post 'notifications/actions/delete_reminder' => 'notifications#execute_delete_reminder'

  get 'learn' => 'learn#index'
  get 'learn/awareness-indicators' => 'learn#awareness_indicators'
  get 'learn/acceptance-voting' => 'learn#acceptance_voting'
  get 'learn/reciprocal-commitment' => 'learn#reciprocal_commitment'
  get 'learn/subagency' => 'learn#subagency'
  get 'learn/superagency' => 'learn#superagency'
  get 'learn/memory' => 'learn#memory'

  get 'whoami' => 'whoami#index'
  get 'motto' => 'motto#index'

  get 'admin' => 'admin#admin'
  get 'admin/actions' => 'admin#actions_index'
  get 'admin/settings' => 'admin#tenant_settings'
  post 'admin/settings' => 'admin#update_tenant_settings'
  get 'admin/settings/actions' => 'admin#actions_index_settings'
  get 'admin/settings/actions/update_tenant_settings' => 'admin#describe_update_tenant_settings'
  post 'admin/settings/actions/update_tenant_settings' => 'admin#execute_update_tenant_settings'
  get 'admin/tenants' => 'admin#tenants'
  get 'admin/tenants/new' => 'admin#new_tenant'
  post 'admin/tenants' => 'admin#create_tenant'
  get 'admin/tenants/new/actions' => 'admin#actions_index_new_tenant'
  get 'admin/tenants/new/actions/create_tenant' => 'admin#describe_create_tenant'
  post 'admin/tenants/new/actions/create_tenant' => 'admin#execute_create_tenant'
  get 'admin/tenants/:subdomain/complete' => 'admin#complete_tenant_creation'
  get 'admin/tenants/:subdomain' => 'admin#show_tenant'
  get 'admin/sidekiq' => 'admin#sidekiq'
  get 'admin/sidekiq/queues/:name' => 'admin#sidekiq_show_queue'
  get 'admin/sidekiq/jobs/:jid' => 'admin#sidekiq_show_job'
  post 'admin/sidekiq/jobs/:jid/retry' => 'admin#sidekiq_retry_job'
  get 'admin/sidekiq/jobs/:jid/actions' => 'admin#actions_index_sidekiq_job'
  get 'admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job' => 'admin#describe_retry_sidekiq_job'
  post 'admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job' => 'admin#execute_retry_sidekiq_job'

  resources :users, path: 'u', param: :handle, only: [:show] do
    get 'settings', on: :member
    post 'settings/profile' => 'users#update_profile', on: :member
    post 'settings/ui_version' => 'users#update_ui_version', on: :member
    patch 'image' => 'users#update_image', on: :member
    resources :api_tokens,
              path: 'settings/tokens',
              only: [:new, :create, :show, :destroy]
    resources :subagents,
              path: "settings/subagents",
              only: [:new, :create, :show, :destroy]
    post 'impersonate' => 'users#impersonate', on: :member
    delete 'impersonate' => 'users#stop_impersonating', on: :member
    post 'add_to_studio' => 'users#add_subagent_to_studio', on: :member
    delete 'remove_from_studio' => 'users#remove_subagent_from_studio', on: :member
    # User settings actions
    get 'settings/actions' => 'users#actions_index', on: :member
    get 'settings/actions/update_profile' => 'users#describe_update_profile', on: :member
    post 'settings/actions/update_profile' => 'users#execute_update_profile', on: :member
    # API token actions
    get 'settings/tokens/new/actions' => 'api_tokens#actions_index', on: :member
    get 'settings/tokens/new/actions/create_api_token' => 'api_tokens#describe_create_api_token', on: :member
    post 'settings/tokens/new/actions/create_api_token' => 'api_tokens#execute_create_api_token', on: :member
    # Subagent actions
    get 'settings/subagents/new/actions' => 'subagents#actions_index', on: :member
    get 'settings/subagents/new/actions/create_subagent' => 'subagents#describe_create_subagent', on: :member
    post 'settings/subagents/new/actions/create_subagent' => 'subagents#execute_create_subagent', on: :member
    # User/Subagent webhook routes (parent can manage subagent webhooks)
    get 'settings/webhooks' => 'user_webhooks#index', on: :member
    get 'settings/webhooks/new' => 'user_webhooks#new', on: :member
    get 'settings/webhooks/new/actions' => 'user_webhooks#actions_index_new', on: :member
    get 'settings/webhooks/new/actions/create_webhook' => 'user_webhooks#describe_create', on: :member
    post 'settings/webhooks/new/actions/create_webhook' => 'user_webhooks#execute_create', on: :member
    get 'settings/webhooks/:webhook_id' => 'user_webhooks#show', on: :member
    get 'settings/webhooks/:webhook_id/actions' => 'user_webhooks#actions_index_show', on: :member
    get 'settings/webhooks/:webhook_id/actions/delete_webhook' => 'user_webhooks#describe_delete', on: :member
    post 'settings/webhooks/:webhook_id/actions/delete_webhook' => 'user_webhooks#execute_delete', on: :member
    get 'settings/webhooks/:webhook_id/actions/test_webhook' => 'user_webhooks#describe_test', on: :member
    post 'settings/webhooks/:webhook_id/actions/test_webhook' => 'user_webhooks#execute_test', on: :member
  end

  ['studios','scenes'].each do |studios_or_scenes|
    get "#{studios_or_scenes}" => "#{studios_or_scenes}#index"
    get "#{studios_or_scenes}/actions" => "#{studios_or_scenes}#actions_index"
    get "#{studios_or_scenes}/new" => "#{studios_or_scenes}#new"
    get "#{studios_or_scenes}/new/actions" => 'studios#actions_index_new'
    get "#{studios_or_scenes}/new/actions/create_studio" => 'studios#describe_create_studio'
    post "#{studios_or_scenes}/new/actions/create_studio" => 'studios#create_studio'
    get "#{studios_or_scenes}/available" => 'studios#handle_available'
    post "#{studios_or_scenes}" => "#{studios_or_scenes}#create"
    get "#{studios_or_scenes}/:superagent_handle" => "#{studios_or_scenes}#show"
    get "#{studios_or_scenes}/:superagent_handle/actions" => 'studios#actions_index_default'
    get "#{studios_or_scenes}/:superagent_handle/actions/send_heartbeat" => 'studios#describe_send_heartbeat'
    post "#{studios_or_scenes}/:superagent_handle/actions/send_heartbeat" => 'studios#send_heartbeat'
    get "#{studios_or_scenes}/:superagent_handle/pinned.html" => 'studios#pinned_items_partial'
    get "#{studios_or_scenes}/:superagent_handle/team.html" => 'studios#team_partial'
    get "#{studios_or_scenes}/:superagent_handle/cycles" => 'cycles#index'
    get "#{studios_or_scenes}/:superagent_handle/cycles/actions" => 'cycles#actions_index_default'
    get "#{studios_or_scenes}/:superagent_handle/cycles/:cycle" => 'cycles#show'
    get "#{studios_or_scenes}/:superagent_handle/cycle/:cycle" => 'cycles#redirect_to_show'
    get "#{studios_or_scenes}/:superagent_handle/views" => 'studios#views'
    get "#{studios_or_scenes}/:superagent_handle/view" => 'studios#view'
    get "#{studios_or_scenes}/:superagent_handle/team" => 'studios#team'
    get "#{studios_or_scenes}/:superagent_handle/settings" => 'studios#settings'
    post "#{studios_or_scenes}/:superagent_handle/settings" => 'studios#update_settings'
    post "#{studios_or_scenes}/:superagent_handle/settings/add_subagent" => 'studios#add_subagent'
    delete "#{studios_or_scenes}/:superagent_handle/settings/remove_subagent" => 'studios#remove_subagent'
    get "#{studios_or_scenes}/:superagent_handle/settings/actions" => 'studios#actions_index_settings'
    get "#{studios_or_scenes}/:superagent_handle/settings/actions/update_studio_settings" => 'studios#describe_update_studio_settings'
    post "#{studios_or_scenes}/:superagent_handle/settings/actions/update_studio_settings" => 'studios#update_studio_settings_action'
    get "#{studios_or_scenes}/:superagent_handle/settings/actions/add_subagent_to_studio" => 'studios#describe_add_subagent_to_studio'
    post "#{studios_or_scenes}/:superagent_handle/settings/actions/add_subagent_to_studio" => 'studios#execute_add_subagent_to_studio'
    get "#{studios_or_scenes}/:superagent_handle/settings/actions/remove_subagent_from_studio" => 'studios#describe_remove_subagent_from_studio'
    post "#{studios_or_scenes}/:superagent_handle/settings/actions/remove_subagent_from_studio" => 'studios#execute_remove_subagent_from_studio'
    # Webhooks
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks" => 'webhooks#index'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/new" => 'webhooks#new'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/new/actions" => 'webhooks#actions_index_new'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/new/actions/create_webhook" => 'webhooks#describe_create_webhook'
    post "#{studios_or_scenes}/:superagent_handle/settings/webhooks/new/actions/create_webhook" => 'webhooks#execute_create_webhook'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id" => 'webhooks#show'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id/actions" => 'webhooks#actions_index'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id/actions/update_webhook" => 'webhooks#describe_update_webhook'
    post "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id/actions/update_webhook" => 'webhooks#execute_update_webhook'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id/actions/delete_webhook" => 'webhooks#describe_delete_webhook'
    post "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id/actions/delete_webhook" => 'webhooks#execute_delete_webhook'
    get "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id/actions/test_webhook" => 'webhooks#describe_test_webhook'
    post "#{studios_or_scenes}/:superagent_handle/settings/webhooks/:id/actions/test_webhook" => 'webhooks#execute_test_webhook'
    patch "#{studios_or_scenes}/:superagent_handle/image" => 'studios#update_image'
    get "#{studios_or_scenes}/:superagent_handle/invite" => 'studios#invite'
    get "#{studios_or_scenes}/:superagent_handle/join" => 'studios#join'
    post "#{studios_or_scenes}/:superagent_handle/join" => 'studios#accept_invite'
    get "#{studios_or_scenes}/:superagent_handle/join/actions" => 'studios#actions_index_join'
    get "#{studios_or_scenes}/:superagent_handle/join/actions/join_studio" => 'studios#describe_join_studio'
    post "#{studios_or_scenes}/:superagent_handle/join/actions/join_studio" => 'studios#join_studio_action'
    get "#{studios_or_scenes}/:superagent_handle/represent" => 'studios#represent'
    post "#{studios_or_scenes}/:superagent_handle/represent" => 'representation_sessions#start_representing'
    get '/representing' => 'representation_sessions#representing'
    delete "#{studios_or_scenes}/:superagent_handle/represent" => 'representation_sessions#stop_representing'
    delete "#{studios_or_scenes}/:superagent_handle/r/:representation_session_id" => 'representation_sessions#stop_representing'
    get "#{studios_or_scenes}/:superagent_handle/representation.html" => 'representation_sessions#index_partial'
    get "#{studios_or_scenes}/:superagent_handle/representation" => 'representation_sessions#index'
    get "#{studios_or_scenes}/:superagent_handle/r/:id" => 'representation_sessions#show'
    post "#{studios_or_scenes}/:superagent_handle/r/:representation_session_id/comments" => 'representation_sessions#create_comment'
    get "#{studios_or_scenes}/:superagent_handle/u/:handle" => 'users#show'
    # Autocomplete endpoints (scoped to studio members)
    get "#{studios_or_scenes}/:superagent_handle/autocomplete/users" => 'autocomplete#users'
    get "#{studios_or_scenes}/:superagent_handle/backlinks" => 'studios#backlinks'
    get "#{studios_or_scenes}/:superagent_handle/backlinks/actions" => 'studios#actions_index_default'
    get "#{studios_or_scenes}/:superagent_handle/heartbeats" => 'heartbeats#index'
    post "#{studios_or_scenes}/:superagent_handle/heartbeats" => 'heartbeats#create'
    get "#{studios_or_scenes}/:superagent_handle/heartbeats/actions" => 'heartbeats#actions_index_default'
    post "#{studios_or_scenes}/:superagent_handle/heartbeats/actions/create_heartbeat" => 'heartbeats#create_heartbeat'
  end

  ['', 'scenes/:superagent_handle', 'studios/:superagent_handle'].each do |prefix|
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
      get '/actions/add_option' => 'decisions#describe_add_option'
      post '/actions/add_option' => 'decisions#add_option'
      get '/actions/vote' => 'decisions#describe_vote'
      post '/actions/vote' => 'decisions#vote'
      get '/actions/add_comment' => 'decisions#describe_add_comment'
      post '/actions/add_comment' => 'decisions#add_comment'
      get '/metric' => 'decisions#metric'
      get '/results.html' => 'decisions#results_partial'
      get '/options.html' => 'decisions#options_partial'
      post '/options.html' => 'decisions#create_option_and_return_options_partial'
      get '/voters.html' => 'decisions#voters_partial'
      post '/comments' => 'decisions#create_comment'
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
        if prefix == 'studios/:superagent_handle'
          # Cycles must be scoped to a studio
          resources :cycles
        else
          # Studios must not be scoped to a studio (doesn't make sense)
          resources :studios
        end
      end
    end
  end
end
