class AddSortKeyToDecisionResultsView < ActiveRecord::Migration[7.2]
  def up
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

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
          encode(digest(d.lottery_beacon_randomness || normalize(o.title, NFC), 'sha256'), 'hex') AS lottery_sort_key,
          o.random_id
      FROM public.options o
          LEFT JOIN public.votes v ON v.option_id = o.id
          LEFT JOIN public.decisions d ON d.id = o.decision_id
      GROUP BY o.tenant_id, o.decision_id, o.id, d.lottery_beacon_randomness
      ORDER BY
          COALESCE(sum(v.accepted), (0)::bigint) DESC,
          COALESCE(sum(v.preferred), (0)::bigint) DESC,
          encode(digest(d.lottery_beacon_randomness || normalize(o.title, NFC), 'sha256'), 'hex') DESC NULLS LAST,
          o.random_id DESC;
    SQL
  end

  def down
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
end
