class ActionsHelper
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
    '/s/:studio_handle' => { actions: [] },
    '/s/:studio_handle/join' => {
      actions: [
        {
          name: 'join_studio',
          params_string: '()',
          description: 'Join a studio',
        }
      ]
    },
    '/s/:studio_handle/settings' => {
      actions: [
        {
          name: 'update_studio_settings',
          params_string: '(name, description, timezone, tempo, synchronization_mode)',
          description: 'Update studio settings',
        }
      ]
    },
    '/s/:studio_handle/cycles' => { actions: [] },
    '/s/:studio_handle/backlinks' => { actions: [] },
    '/s/:studio_handle/team' => { actions: [] },
    '/s/:studio_handle/note' => {
      actions: [
        {
          name: 'create_note',
          params_string: '(title, text, deadline)',
          description: 'Create a new note',
        }
      ]
    },
    '/s/:studio_handle/n/:note_id' => {
      actions: [
        {
          name: 'confirm_read',
          params_string: '()',
          description: 'Confirm that you have read the note',
        }
      ]
    },
    '/s/:studio_handle/n/:note_id/edit' => {
      actions: [
        {
          name: 'update_note',
          params_string: '(title, text, deadline)',
          description: 'Update the note',
        }
      ]
    },
    '/s/:studio_handle/decide' => {
      actions: [
        {
          name: 'create_decision',
          params_string: '(question, description, options_open, deadline)',
          description: 'Create a new decision',
        }
      ]
    },
    '/s/:studio_handle/d/:decision_id' => {
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
    '/s/:studio_handle/d/:decision_id/settings' => {
      actions: [
        {
          name: 'update_decision_settings',
          params_string: '(question, description, options_open, deadline)',
          description: 'Update the decision settings',
        }
      ]
    },
    '/s/:studio_handle/commit' => {
      actions: [
        {
          name: 'create_commitment',
          params_string: '(title, description, critical_mass, deadline)',
          description: 'Create a new commitment',
        }
      ]
    },
    '/s/:studio_handle/c/:commitment_id' => {
      actions: [
        {
          name: 'join_commitment',
          params_string: '()',
          description: 'Join the commitment',
        }
      ]
    },
    '/s/:studio_handle/c/:commitment_id/settings' => {
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

  def self.actions_by_route
    @@actions_by_route
  end

  def self.routes_and_actions
    @@routes_and_actions
  end

  def self.actions_for_route(route)
    @@actions_by_route[route]
  end

end
