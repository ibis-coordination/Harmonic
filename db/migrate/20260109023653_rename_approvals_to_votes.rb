class RenameApprovalsToVotes < ActiveRecord::Migration[7.0]
  def up
    # Rename the table
    rename_table :approvals, :votes

    # Rename columns
    rename_column :votes, :value, :accepted
    rename_column :votes, :stars, :preferred

    # Drop and recreate the decision_results view with new column names
    execute "DROP VIEW IF EXISTS public.decision_results"
    execute <<-SQL
      CREATE VIEW public.decision_results AS
      SELECT o.tenant_id,
          o.decision_id,
          o.id AS option_id,
          o.title AS option_title,
          COALESCE(sum(v.accepted), (0)::bigint) AS accepted_yes,
          (count(v.accepted) - COALESCE(sum(v.accepted), (0)::bigint)) AS accepted_no,
          count(v.accepted) AS vote_count,
          COALESCE(sum(v.preferred), (0)::bigint) AS preferred,
          o.random_id
      FROM (public.options o
          LEFT JOIN public.votes v ON ((v.option_id = o.id)))
      GROUP BY o.tenant_id, o.decision_id, o.id
      ORDER BY COALESCE(sum(v.accepted), (0)::bigint) DESC, COALESCE(sum(v.preferred), (0)::bigint) DESC, o.random_id DESC;
    SQL
  end

  def down
    # Drop and recreate the original decision_results view
    execute "DROP VIEW IF EXISTS public.decision_results"
    execute <<-SQL
      CREATE VIEW public.decision_results AS
      SELECT o.tenant_id,
          o.decision_id,
          o.id AS option_id,
          o.title AS option_title,
          COALESCE(sum(a.value), (0)::bigint) AS approved_yes,
          (count(a.value) - COALESCE(sum(a.value), (0)::bigint)) AS approved_no,
          count(a.value) AS approval_count,
          COALESCE(sum(a.stars), (0)::bigint) AS stars,
          o.random_id
      FROM (public.options o
          LEFT JOIN public.approvals a ON ((a.option_id = o.id)))
      GROUP BY o.tenant_id, o.decision_id, o.id
      ORDER BY COALESCE(sum(a.value), (0)::bigint) DESC, COALESCE(sum(a.stars), (0)::bigint) DESC, o.random_id DESC;
    SQL

    # Rename columns back
    rename_column :votes, :accepted, :value
    rename_column :votes, :preferred, :stars

    # Rename the table back
    rename_table :votes, :approvals
  end
end
