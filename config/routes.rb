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
      get 'scratchpad', to: 'scratchpad#show'
      put 'scratchpad', to: 'scratchpad#update'
      post 'scratchpad/append', to: 'scratchpad#append'
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
      # resources :webhooks
      get 'custom/data', to: 'custom_data#info'
      get 'custom/config', to: 'custom_data#configuration'
      get 'custom/data/:table_name/:id/history', to: 'custom_data#history'
      resources :custom_data, path: 'custom/data/:parent_table_name/:parent_id/:table_name' do
        get 'history', to: 'custom_data#history'
      end
      resources :custom_data, path: 'custom/data/:table_name'
    end
  end
  # Defines the root path route ("/")
  root 'home#index'
  get 'home' => 'home#index'
  get 'settings' => 'home#settings'
  get 'scratchpad' => 'home#scratchpad'

  get 'about' => 'home#about'
  get 'help' => 'home#help'
  get 'contact' => 'home#contact'

  get 'learn' => 'learn#index'
  get 'learn/awareness-indicators' => 'learn#awareness_indicators'
  get 'learn/acceptance-voting' => 'learn#acceptance_voting'
  get 'learn/reciprocal-commitment' => 'learn#reciprocal_commitment'

  get 'games' => 'games#index'
  post 'games/chess' => 'games#create_chess_match'
  get 'games/chess/:id' => 'games#show_chess_match'
  post 'games/chess/:id/join' => 'games#join_chess_match'
  post 'games/chess/:id/vote' => 'games#vote_on_chess_move'
  post 'games/chess/:id/commit' => 'games#commit_to_chess_move'
  get 'games/chess/:id/poll' => 'games#poll_chess_match'

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
    get 'scratchpad' => 'users#scratchpad', on: :member
    put 'scratchpad' => 'users#scratchpad', on: :member
    post 'scratchpad/append' => 'users#append_to_scratchpad', on: :member
    get 'settings', on: :member
    patch 'image' => 'users#update_image', on: :member
    resources :api_tokens,
              path: 'settings/tokens',
              only: [:new, :create, :show, :destroy]
    post 'impersonate' => 'users#impersonate', on: :member
    delete 'impersonate' => 'users#stop_impersonating', on: :member
  end

  get 'studios' => 'studios#index'
  get 'studios/new' => 'studios#new'
  get 'studios/available' => 'studios#handle_available'
  post 'studios' => 'studios#create'
  get 's/:studio_handle' => 'studios#show'
  get 's/:studio_handle/pinned.html' => 'studios#pinned_items_partial'
  get 's/:studio_handle/team.html' => 'studios#team_partial'
  get "s/:studio_handle/cycles" => 'cycles#index'
  get "s/:studio_handle/cycles/:cycle" => 'cycles#show'
  get "s/:studio_handle/cycle/:cycle" => 'cycles#redirect_to_show'
  get "s/:studio_handle/views" => 'studios#views'
  get "s/:studio_handle/view" => 'studios#view'
  get "s/:studio_handle/team" => 'studios#team'
  get "s/:studio_handle/settings" => 'studios#settings'
  post "s/:studio_handle/settings" => 'studios#update_settings'
  patch "s/:studio_handle/image" => 'studios#update_image'
  get "s/:studio_handle/invite" => 'studios#invite'
  get "s/:studio_handle/join" => 'studios#join'
  post "s/:studio_handle/join" => 'studios#accept_invite'
  get 's/:studio_handle/represent' => 'studios#represent'
  post 's/:studio_handle/represent' => 'representation_sessions#start_representing'
  get '/representing' => 'representation_sessions#representing'
  delete 's/:studio_handle/represent' => 'representation_sessions#stop_representing'
  delete 's/:studio_handle/r/:representation_session_id' => 'representation_sessions#stop_representing'
  get 's/:studio_handle/representation' => 'representation_sessions#index'
  get 's/:studio_handle/r/:id' => 'representation_sessions#show'
  get 's/:studio_handle/u/:handle' => 'users#show'
  get 's/:studio_handle/backlinks' => 'studios#backlinks'

  ['', 's/:studio_handle'].each do |prefix|
    get "#{prefix}/note" => 'notes#new'
    post "#{prefix}/note" => 'notes#create'
    resources :notes, only: [:show], path: "#{prefix}/n" do
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
    resources :decisions, only: [:show], path: "#{prefix}/d" do
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

    get "#{prefix}/sequence" => 'sequences#new'
    post "#{prefix}/sequence" => 'sequences#create'
    resources :sequences, only: [:show], path: "#{prefix}/sq" do
      get '/edit' => 'sequences#edit'
      post '/edit' => 'sequences#update'
      put '/pin' => 'sequences#pin'
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
        if prefix == 's/:studio_handle'
          # Cycles must be scoped to a studio
          resources :cycles
        else
          # Studios must not be scoped to a studio (doesn't make sense)
          resources :studios
        end
        # resources :webhooks
        get 'custom/data', to: 'custom_data#info'
        get 'custom/config', to: 'custom_data#configuration'
        get 'custom/data/:table_name/:id/history', to: 'custom_data#history'
        resources :custom_data, path: 'custom/data/:parent_table_name/:parent_id/:table_name' do
          get 'history', to: 'custom_data#history'
        end
        resources :custom_data, path: 'custom/data/:table_name'
      end
    end

    namespace :readybase, path: "#{prefix}/readybase" do
      get '' => 'main#index'
      get 'main' => 'main#index'
    end

    namespace :pages, path: "#{prefix}/pages" do
      get '' => 'main#index'
      get 'new' => 'main#new'
      post 'publish' => 'main#publish'
      get ':path/edit' => 'main#edit'
      put ':path/edit' => 'main#update'
      get ':path' => 'main#show'
    end

    namespace :random, path: "#{prefix}/random" do
      get '' => 'main#index'
      get 'new' => 'main#new'
      get 'beacon' => 'main#beacon'
      get 'cointoss' => 'main#cointoss'
      get 'shuffle' => 'main#shuffle_items'
      post 'shuffle' => 'main#shuffle_items'
    end

  end
end
