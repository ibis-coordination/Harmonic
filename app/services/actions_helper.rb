# typed: true

class ActionsHelper
  extend T::Sig
  @@actions_by_route = {
    '/studios' => { actions: [] },
    '/studios/new' => {
      actions: [
        {
          name: 'create_studio',
          params_string: '(name, handle, description, timezone, tempo, synchronization_mode, invitations, representation, file_uploads, api_enabled)',
          description: 'Create a new studio',
        }
      ]
    },
    '/studios/:studio_handle' => { actions: [] },
    '/studios/:studio_handle/join' => {
      actions: [
        {
          name: 'join_studio',
          params_string: '()',
          description: 'Join a studio',
        }
      ]
    },
    '/studios/:studio_handle/settings' => {
      actions: [
        {
          name: 'update_studio_settings',
          params_string: '(name, description, timezone, tempo, synchronization_mode, invitations, representation, file_uploads, api_enabled)',
          description: 'Update studio settings',
        },
        {
          name: 'add_subagent_to_studio',
          params_string: '(subagent_id)',
          description: 'Add one of your subagents to this studio',
        },
        {
          name: 'remove_subagent_from_studio',
          params_string: '(subagent_id)',
          description: 'Remove a subagent from this studio',
        }
      ]
    },
    '/studios/:studio_handle/cycles' => { actions: [] },
    '/studios/:studio_handle/backlinks' => { actions: [] },
    '/studios/:studio_handle/team' => { actions: [] },
    '/studios/:studio_handle/note' => {
      actions: [
        {
          name: 'create_note',
          params_string: '(text)',
          description: 'Create a new note',
        }
      ]
    },
    '/studios/:studio_handle/n/:note_id' => {
      actions: [
        {
          name: 'confirm_read',
          params_string: '()',
          description: 'Confirm that you have read the note',
        }, {
          name: 'add_comment',
          params_string: '(text)',
          description: 'Add a comment to this note',
        }
      ]
    },
    '/studios/:studio_handle/n/:note_id/edit' => {
      actions: [
        {
          name: 'update_note',
          params_string: '(text)',
          description: 'Update the note',
        }
      ]
    },
    '/studios/:studio_handle/decide' => {
      actions: [
        {
          name: 'create_decision',
          params_string: '(question, description, options_open, deadline)',
          description: 'Create a new decision',
        }
      ]
    },
    '/studios/:studio_handle/d/:decision_id' => {
      actions: [
        {
          name: 'add_option',
          params_string: '(title)',
          description: 'Add an option to the options list',
        }, {
          name: 'vote',
          params_string: '(option_title, accept, prefer)',
          description: 'Vote on an option',
        }, {
          name: 'add_comment',
          params_string: '(text)',
          description: 'Add a comment to this decision',
        }
      ]
    },
    '/studios/:studio_handle/d/:decision_id/settings' => {
      actions: [
        {
          name: 'update_decision_settings',
          params_string: '(question, description, options_open, deadline)',
          description: 'Update the decision settings',
        }
      ]
    },
    '/studios/:studio_handle/commit' => {
      actions: [
        {
          name: 'create_commitment',
          params_string: '(title, description, critical_mass, deadline)',
          description: 'Create a new commitment',
        }
      ]
    },
    '/studios/:studio_handle/c/:commitment_id' => {
      actions: [
        {
          name: 'join_commitment',
          params_string: '()',
          description: 'Join the commitment',
        }, {
          name: 'add_comment',
          params_string: '(text)',
          description: 'Add a comment to this commitment',
        }
      ]
    },
    '/studios/:studio_handle/c/:commitment_id/settings' => {
      actions: [
        {
          name: 'update_commitment_settings',
          params_string: '(title, description, critical_mass, deadline)',
          description: 'Update the commitment settings',
        }
      ]
    },
    '/u/:handle/settings' => {
      actions: [
        {
          name: 'update_profile',
          params_string: '(name, new_handle)',
          description: 'Update your profile name and/or handle',
        }
      ]
    },
    '/u/:handle/settings/tokens/new' => {
      actions: [
        {
          name: 'create_api_token',
          params_string: '(name, read_write, duration, duration_unit)',
          description: 'Create a new API token',
        }
      ]
    },
    '/u/:handle/settings/subagents/new' => {
      actions: [
        {
          name: 'create_subagent',
          params_string: '(name, generate_token)',
          description: 'Create a new subagent',
        }
      ]
    },
    '/admin' => { actions: [] },
    '/admin/settings' => {
      actions: [
        {
          name: 'update_tenant_settings',
          params_string: '(name, timezone, api_enabled, require_login, allow_file_uploads)',
          description: 'Update tenant settings',
        }
      ]
    },
    '/admin/tenants/new' => {
      actions: [
        {
          name: 'create_tenant',
          params_string: '(subdomain, name)',
          description: 'Create a new tenant',
        }
      ]
    },
    '/admin/sidekiq/jobs/:jid' => {
      actions: [
        {
          name: 'retry_sidekiq_job',
          params_string: '()',
          description: 'Retry this Sidekiq job',
        }
      ]
    },
  }
  @@routes_and_actions = @@actions_by_route.keys.map do |route|
    {
      route: route,
      actions: @@actions_by_route[route][:actions]
    }
  end.sort_by { |item| item[:route] }

  sig { returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
  def self.actions_by_route
    @@actions_by_route
  end

  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.routes_and_actions
    @@routes_and_actions
  end

  sig { params(route: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.actions_for_route(route)
    @@actions_by_route[route]
  end

end
