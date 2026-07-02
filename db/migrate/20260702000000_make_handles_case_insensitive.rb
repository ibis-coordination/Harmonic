# Makes user and collective handles case-INSENSITIVE for lookup and uniqueness
# while PRESERVING the display case the user actually chose (GitHub-style).
#
# Mechanism: convert the `handle` columns from `varchar` to the `citext`
# ("case-insensitive text") type. citext compares and indexes
# case-insensitively, so:
#
#   * the existing UNIQUE (tenant_id, handle) indexes now reject "Linus" when
#     "linus" already exists — no schema change to the indexes themselves;
#     Postgres rebuilds them with the citext comparator automatically.
#   * every existing `find_by(handle:)` / `where(handle:)` callsite becomes
#     case-insensitive with no Ruby change, so `/u/Linus` and `/u/linus`
#     resolve to the same identity.
#   * the stored value keeps its original case, so profiles and mentions can
#     render "Linus" instead of a normalized slug.
#
# Existing data is safe to convert: handles were lowercased on save until now,
# so no two rows differ only by case and the unique indexes cannot be violated
# by the type change.
class MakeHandlesCaseInsensitive < ActiveRecord::Migration[7.2]
  def up
    enable_extension "citext" unless extension_enabled?("citext")

    change_column :tenant_users, :handle, :citext
    change_column :collectives, :handle, :citext
  end

  def down
    # citext -> varchar is a safe lossless cast (citext is text under the hood).
    # The extension is left enabled; dropping it would fail while the columns
    # still reference the type, and it is harmless to keep.
    change_column :tenant_users, :handle, :string
    change_column :collectives, :handle, :string
  end
end
