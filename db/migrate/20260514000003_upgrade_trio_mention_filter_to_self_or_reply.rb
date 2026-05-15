# Upgrades any default-shaped Trio "Respond to mentions" AutomationRule
# from mention_filter "self" to "self_or_reply", so existing trios start
# responding to replies on their own comments without requiring a re-seed.
#
# Narrow by intent: only rules whose trigger_config still has
# mention_filter "self" on note.created and that belong to a User with
# system_role "trio". Rules a collective admin customized to use a
# different filter are left alone.
class UpgradeTrioMentionFilterToSelfOrReply < ActiveRecord::Migration[7.2]
  def up
    rules = AutomationRule.joins(:ai_agent).where(users: { system_role: "trio" })
      .where("trigger_config @> ?", { event_type: "note.created", mention_filter: "self" }.to_json)

    rules.find_each do |rule|
      cfg = rule.trigger_config.merge("mention_filter" => "self_or_reply")
      rule.update!(
        trigger_config: cfg,
        name: "Respond to mentions and replies",
        description: "When @trio is mentioned, or when someone replies to a comment Trio wrote, navigate and respond.",
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Reverting would require knowing which rules were originally 'self' " \
          "vs. user-edited to 'self_or_reply'. Revert by editing rules manually."
  end
end
