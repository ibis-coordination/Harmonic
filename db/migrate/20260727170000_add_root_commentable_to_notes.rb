# Denormalize the thread root onto each comment.
#
# `Note#root_commentable` used to walk the polymorphic `commentable` chain at
# read time with a `break if depth > 20` guard. Past that ceiling the walk
# stopped early and returned the ancestor it happened to land on *as if it
# were the root*, silently. That broke replies on deep threads
# (`resolve_replying_to` compares roots) and pointed `display_path` /
# `thread_root` at the wrong resource (issue #539).
#
# Storing the root removes the ceiling entirely: a new comment inherits its
# parent's root in one hop, so there is no chain to walk at any depth.
class AddRootCommentableToNotes < ActiveRecord::Migration[7.2]
  def up
    add_column :notes, :root_commentable_type, :string
    add_column :notes, :root_commentable_id, :uuid
    add_index :notes, [:root_commentable_type, :root_commentable_id],
              name: "index_notes_on_root_commentable"

    # Backfill downward from the roots. Seed rule: a comment whose parent is
    # not itself a comment sits directly on its root, so root = commentable.
    # That covers both non-Note commentables (Decision, Commitment, ... —
    # those can never be comments) and comments on standalone Notes. Then
    # each generation inherits from its parent. Iterating (rather than a
    # recursive CTE) is what makes this terminate on a hypothetical
    # `commentable` cycle — a cycle never gets a root, so it produces no
    # updates and the loop exits.
    execute <<~SQL.squish
      UPDATE notes
      SET root_commentable_type = notes.commentable_type,
          root_commentable_id = notes.commentable_id
      WHERE notes.subtype = 'comment'
        AND notes.commentable_id IS NOT NULL
        AND (notes.commentable_type <> 'Note'
             OR EXISTS (SELECT 1 FROM notes parent
                        WHERE parent.id = notes.commentable_id
                          AND parent.subtype <> 'comment'))
    SQL

    # Each pass resolves one more level of nesting, so this runs as many
    # times as the deepest thread is deep. Deliberately uncapped: a cap is
    # what caused #539 in the first place, and this terminates on its own —
    # every pass either fills at least one row from a finite set or stops.
    loop do
      updated = execute(<<~SQL.squish).cmd_tuples
        UPDATE notes
        SET root_commentable_type = parent.root_commentable_type,
            root_commentable_id = parent.root_commentable_id
        FROM notes parent
        WHERE notes.commentable_type = 'Note'
          AND notes.commentable_id = parent.id
          AND notes.subtype = 'comment'
          AND notes.root_commentable_id IS NULL
          AND parent.root_commentable_id IS NOT NULL
      SQL
      break if updated.zero?
    end

    orphaned = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM notes
      WHERE subtype = 'comment'
        AND commentable_id IS NOT NULL
        AND root_commentable_id IS NULL
    SQL
    say "#{orphaned} comment(s) left without a root (dangling or cyclic commentable chain)" if orphaned.positive?
  end

  def down
    remove_index :notes, name: "index_notes_on_root_commentable"
    remove_column :notes, :root_commentable_id
    remove_column :notes, :root_commentable_type
  end
end
