Rails.application.routes.draw do
  get 'healthcheck' => 'healthcheck#healthcheck'

  if ENV['AUTH_MODE'] == 'honor_system'
    get 'login' => 'honor_system_sessions#new'
    post 'login' => 'honor_system_sessions#create'
    delete 'logout' => 'honor_system_sessions#destroy'
    get 'logout-success' => 'honor_system_sessions#logout_success'
  elsif ENV['AUTH_MODE'] == 'oauth'
    get 'login' => 'sessions#new'
    get 'auth/:provider/callback' => 'sessions#oauth_callback'
    get 'login/return' => 'sessions#return'
    get 'login/callback' => 'sessions#internal_callback'
    delete '/logout' => 'sessions#destroy'
    get 'logout-success' => 'sessions#logout_success'
  elsif ENV['AUTH_MODE'] == 'magic_link'
    # TODO - implement magic link auth
    # get 'login' => 'magic_link_sessions#new'
    # post 'login' => 'magic_link_sessions#create'
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
          resources :approvals
        end
        resources :options do
          resources :approvals
        end
        resources :approvals
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
  end
  # Defines the root path route ("/")
  root 'home#index'
  get 'home' => 'home#index'
  get 'actions' => 'home#actions_index'
  get 'settings' => 'home#settings'

  get 'about' => 'home#about'
  get 'help' => 'home#help'
  get 'contact' => 'home#contact'

  get 'learn' => 'learn#index'
  get 'learn/awareness-indicators' => 'learn#awareness_indicators'
  get 'learn/acceptance-voting' => 'learn#acceptance_voting'
  get 'learn/reciprocal-commitment' => 'learn#reciprocal_commitment'

  get 'admin' => 'admin#admin'
  get 'admin/settings' => 'admin#tenant_settings'
  post 'admin/settings' => 'admin#update_tenant_settings'
  get 'admin/tenants' => 'admin#tenants'
  get 'admin/tenants/new' => 'admin#new_tenant'
  post 'admin/tenants' => 'admin#create_tenant'
  get 'admin/tenants/:subdomain/complete' => 'admin#complete_tenant_creation'
  get 'admin/tenants/:subdomain' => 'admin#show_tenant'
  get 'admin/sidekiq' => 'admin#sidekiq'
  get 'admin/sidekiq/queues/:name' => 'admin#sidekiq_show_queue'
  get 'admin/sidekiq/jobs/:jid' => 'admin#sidekiq_show_job'
  post 'admin/sidekiq/jobs/:jid/retry' => 'admin#sidekiq_retry_job'

  resources :users, path: 'u', param: :handle, only: [:show] do
    get 'settings', on: :member
    post 'settings/profile' => 'users#update_profile', on: :member
    patch 'image' => 'users#update_image', on: :member
    resources :api_tokens,
              path: 'settings/tokens',
              only: [:new, :create, :show, :destroy]
    resources :simulated_users,
              path: 'settings/simulated_users',
              only: [:new, :create, :show, :destroy]
    post 'impersonate' => 'users#impersonate', on: :member
    delete 'impersonate' => 'users#stop_impersonating', on: :member
  end

  get 'studios' => 'studios#index'
  get 'studios/new' => 'studios#new'
  get 'studios/new/actions' => 'studios#actions_index_new'
  get 'studios/new/actions/create_studio' => 'studios#describe_create_studio'
  post 'studios/new/actions/create_studio' => 'studios#create_studio'
  get 'studios/available' => 'studios#handle_available'
  post 'studios' => 'studios#create'
  get 'studios/:studio_handle' => 'studios#show'
  get 'studios/:studio_handle/actions' => 'studios#actions_index_default'
  get 'studios/:studio_handle/pinned.html' => 'studios#pinned_items_partial'
  get 'studios/:studio_handle/team.html' => 'studios#team_partial'
  get "studios/:studio_handle/cycles" => 'cycles#index'
  get "studios/:studio_handle/cycles/actions" => 'cycles#actions_index_default'
  get "studios/:studio_handle/cycles/:cycle" => 'cycles#show'
  get "studios/:studio_handle/cycle/:cycle" => 'cycles#redirect_to_show'
  get "studios/:studio_handle/views" => 'studios#views'
  get "studios/:studio_handle/view" => 'studios#view'
  get "studios/:studio_handle/team" => 'studios#team'
  get "studios/:studio_handle/settings" => 'studios#settings'
  post "studios/:studio_handle/settings" => 'studios#update_settings'
  patch "studios/:studio_handle/image" => 'studios#update_image'
  get "studios/:studio_handle/invite" => 'studios#invite'
  get "studios/:studio_handle/join" => 'studios#join'
  post "studios/:studio_handle/join" => 'studios#accept_invite'
  get 'studios/:studio_handle/represent' => 'studios#represent'
  post 'studios/:studio_handle/represent' => 'representation_sessions#start_representing'
  get '/representing' => 'representation_sessions#representing'
  delete 'studios/:studio_handle/represent' => 'representation_sessions#stop_representing'
  delete 'studios/:studio_handle/r/:representation_session_id' => 'representation_sessions#stop_representing'
  get 'studios/:studio_handle/representation.html' => 'representation_sessions#index_partial'
  get 'studios/:studio_handle/representation' => 'representation_sessions#index'
  get 'studios/:studio_handle/r/:id' => 'representation_sessions#show'
  get 'studios/:studio_handle/u/:handle' => 'users#show'
  get 'studios/:studio_handle/backlinks' => 'studios#backlinks'
  get "studios/:studio_handle/backlinks/actions" => 'studios#actions_index_default'
  get "studios/:studio_handle/heartbeats" => 'heartbeats#index'
  post "studios/:studio_handle/heartbeats" => 'heartbeats#create'
  get "studios/:studio_handle/heartbeats/actions" => 'heartbeats#actions_index_default'
  post "studios/:studio_handle/heartbeats/actions/create_heartbeat" => 'heartbeats#create_heartbeat'

  ['', 'studios/:studio_handle'].each do |prefix|
    get "#{prefix}/note" => 'notes#new'
    post "#{prefix}/note" => 'notes#create'
    get "#{prefix}/note/actions" => 'notes#actions_index_new'
    get "#{prefix}/note/actions/create_note" => 'notes#describe_create_note'
    post "#{prefix}/note/actions/create_note" => 'notes#create_note'
    resources :notes, only: [:show], path: "#{prefix}/n" do
      get '/actions' => 'notes#actions_index_show'
      get '/actions/confirm_read' => 'notes#describe_confirm_read'
      post '/actions/confirm_read' => 'notes#confirm_read'
      get '/edit/actions' => 'notes#actions_index_edit'
      get '/edit/actions/update_note' => 'notes#describe_update_note'
      post '/edit/actions/update_note' => 'notes#update_note'
      get '/metric' => 'notes#metric'
      get '/edit' => 'notes#edit'
      post '/edit' => 'notes#update'
      get '/history.html' => 'notes#history_log_partial'
      post '/confirm.html' => 'notes#confirm_and_return_partial'
      put '/pin' => 'notes#pin'
      get '/attachments/:attachment_id' => 'attachments#show'
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
      get '/metric' => 'decisions#metric'
      get '/results.html' => 'decisions#results_partial'
      get '/options.html' => 'decisions#options_partial'
      post '/options.html' => 'decisions#create_option_and_return_options_partial'
      get '/voters.html' => 'decisions#voters_partial'
      put '/pin' => 'decisions#pin'
      get '/attachments/:attachment_id' => 'attachments#show'
      post '/duplicate' => 'decisions#duplicate'
      get '/settings' => 'decisions#settings'
      post '/settings' => 'decisions#update_settings'
    end

    get "#{prefix}/commit" => 'commitments#new'
    post "#{prefix}/commit" => 'commitments#create'
    resources :commitments, only: [:show], path: "#{prefix}/c" do
      get '/metric' => 'commitments#metric'
      get '/status.html' => 'commitments#status_partial'
      get '/participants.html' => 'commitments#participants_list_items_partial'
      post '/join.html' => 'commitments#join_and_return_partial'
      put '/pin' => 'commitments#pin'
      get '/attachments/:attachment_id' => 'attachments#show'
      get '/settings' => 'commitments#settings'
      post '/settings' => 'commitments#update_settings'
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
            resources :approvals
          end
          resources :options do
            resources :approvals
          end
          resources :approvals
        end
        resources :commitments do
          post :join, to: 'commitments#join'
          resources :participants
        end
        if prefix == 'studios/:studio_handle'
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
