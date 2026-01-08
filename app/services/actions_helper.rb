# typed: true

class ActionsHelper
  extend T::Sig
  @@actions_by_route = {
    '/studios' => { actions: [] },
    '/studios/new' => {
      actions: [
        {
          name: 'create_studio',
          params_string: '(name, handle, description, timezone, tempo, synchronization_mode)',
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
          params_string: '(name, description, timezone, tempo, synchronization_mode)',
          description: 'Update studio settings',
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
          params_string: '(title, text, deadline)',
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
        }
      ]
    },
    '/studios/:studio_handle/n/:note_id/edit' => {
      actions: [
        {
          name: 'update_note',
          params_string: '(title, text, deadline)',
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
    }
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
