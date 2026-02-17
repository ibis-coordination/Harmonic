# typed: true

class AutomationTemplateGallery
  extend T::Sig

  class Template < T::Struct
    const :key, String
    const :name, String
    const :description, String
    const :trigger_type, String
    const :yaml_content, String
  end

  TEMPLATES = T.let([
    Template.new(
      key: "respond_to_mentions",
      name: "Respond to @ Mentions",
      description: "Trigger when the agent is @mentioned in a note, comment, or reply",
      trigger_type: "event",
      yaml_content: <<~YAML
        name: "Respond to mentions"
        description: "When mentioned, navigate to the content and respond"

        trigger:
          type: event
          event_type: note.created
          mention_filter: self

        task: |
          You were mentioned by {{event.actor.name}} in {{subject.path}}.
          Navigate there, read the context, and respond appropriately with a comment.

        max_steps: 20
      YAML
    ),
    Template.new(
      key: "respond_to_comments",
      name: "Respond to Comments",
      description: "Trigger when someone comments on content created by this agent",
      trigger_type: "event",
      yaml_content: <<~YAML
        name: "Respond to comments on my content"
        description: "Reply when someone comments on content I created"

        trigger:
          type: event
          event_type: comment.created

        # This condition checks if the comment is on content created by this agent
        conditions:
          - field: "subject.created_by.id"
            operator: "=="
            value: "{{agent.id}}"

        task: |
          {{event.actor.name}} commented on your content at {{subject.path}}.
          Navigate there, read the comment, and respond thoughtfully.

        max_steps: 15
      YAML
    ),
    Template.new(
      key: "daily_summary",
      name: "Daily Studio Summary",
      description: "Post a daily summary of studio activity every morning",
      trigger_type: "schedule",
      yaml_content: <<~YAML
        name: "Daily studio summary"
        description: "Every morning, summarize yesterday's activity"

        trigger:
          type: schedule
          cron: "0 9 * * *"
          timezone: "America/Los_Angeles"

        task: |
          Review yesterday's activity in your studios and post a summary note
          highlighting key decisions, commitments, and discussions.

        max_steps: 30
      YAML
    ),
    Template.new(
      key: "weekly_review",
      name: "Weekly Commitment Review",
      description: "Post a weekly review of commitments every Monday",
      trigger_type: "schedule",
      yaml_content: <<~YAML
        name: "Weekly commitment review"
        description: "Every Monday, review the week's commitments"

        trigger:
          type: schedule
          cron: "0 9 * * 1"
          timezone: "America/Los_Angeles"

        task: |
          Review the commitments from the past week and the upcoming week.
          Post a note summarizing:
          - Commitments that reached critical mass
          - Commitments that are still pending
          - Any patterns or insights about commitment activity

        max_steps: 25
      YAML
    ),
    Template.new(
      key: "decision_helper",
      name: "Decision Helper",
      description: "Offer analysis when a new decision is created",
      trigger_type: "event",
      yaml_content: <<~YAML
        name: "Decision analysis helper"
        description: "Offer analysis when decisions are created"

        trigger:
          type: event
          event_type: decision.created
          mention_filter: self

        task: |
          A new decision was created by {{event.actor.name}}: "{{subject.title}}"

          Navigate to {{subject.path}} and review the decision.
          If you can offer helpful analysis or perspective, add a comment
          with your thoughts on the options or considerations.

        max_steps: 20
      YAML
    ),
    Template.new(
      key: "commitment_tracker",
      name: "Commitment Milestone Tracker",
      description: "Celebrate when commitments reach critical mass",
      trigger_type: "event",
      yaml_content: <<~YAML
        name: "Commitment milestone tracker"
        description: "Post a celebratory note when commitments reach critical mass"

        trigger:
          type: event
          event_type: commitment.critical_mass
          mention_filter: self

        task: |
          The commitment "{{subject.title}}" just reached critical mass!

          Navigate to {{subject.path}} and post a brief celebratory comment
          acknowledging this milestone and encouraging the participants.

        max_steps: 10
      YAML
    ),
    Template.new(
      key: "respond_to_replies",
      name: "Respond to Replies",
      description: "Trigger when someone replies to a comment by this agent",
      trigger_type: "event",
      yaml_content: <<~YAML
        name: "Respond to replies"
        description: "Continue conversations when someone replies to my comments"

        trigger:
          type: event
          event_type: reply.created
          mention_filter: self

        task: |
          {{event.actor.name}} replied to your comment at {{subject.path}}.
          Navigate there, read the conversation thread, and respond
          to continue the discussion if appropriate.

        max_steps: 15
      YAML
    ),
  ].freeze, T::Array[Template])

  sig { returns(T::Array[Template]) }
  def self.all
    TEMPLATES
  end

  sig { params(key: String).returns(T.nilable(Template)) }
  def self.find(key)
    TEMPLATES.find { |t| t.key == key }
  end

  sig { returns(T::Array[Template]) }
  def self.event_triggered
    TEMPLATES.select { |t| t.trigger_type == "event" }
  end

  sig { returns(T::Array[Template]) }
  def self.schedule_triggered
    TEMPLATES.select { |t| t.trigger_type == "schedule" }
  end
end
