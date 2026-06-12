# typed: true

# Comments now emit comment.* events instead of note.* events. Rules that
# respond to replies (mention_filter self_or_reply, e.g. Trio's seeded
# "Respond to mentions and replies") matched comments via note.created;
# widen them to the event_types array form covering both, so they keep
# firing on replies.
class WidenReplyRulesToCommentEvents < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE automation_rules
      SET trigger_config = (trigger_config - 'event_type')
        || jsonb_build_object('event_types', jsonb_build_array('note.created', 'comment.created'))
      WHERE trigger_type = 'event'
        AND trigger_config->>'event_type' = 'note.created'
        AND trigger_config->>'mention_filter' = 'self_or_reply'
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE automation_rules
      SET trigger_config = (trigger_config - 'event_types')
        || jsonb_build_object('event_type', 'note.created')
      WHERE trigger_type = 'event'
        AND trigger_config->'event_types' = '["note.created", "comment.created"]'::jsonb
        AND trigger_config->>'mention_filter' = 'self_or_reply'
    SQL
  end
end
