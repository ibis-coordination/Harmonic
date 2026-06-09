# typed: true

# Precomputes per-(viewer, target) tune-in state for batch rendering of
# tune-in buttons. Returns two Sets so the view can do O(1) lookups while
# iterating rows — no per-row queries.
class TuneInState
  extend T::Sig

  class Result < T::Struct
    const :on_list_ids,      T::Set[String]
    const :blocked_pair_ids, T::Set[String]
  end

  sig do
    params(viewer: T.nilable(User), target_ids: T::Array[String], tenant: Tenant)
      .returns(Result)
  end
  def self.compute(viewer:, target_ids:, tenant:)
    return Result.new(on_list_ids: Set.new, blocked_pair_ids: Set.new) if viewer.nil? || target_ids.empty?

    primary_list_id = UserList
      .tenant_scoped_only(tenant.id)
      .where(owner_id: viewer.id, is_primary: true, deleted_at: nil)
      .pick(:id)
    on_list_ids = primary_list_id ?
      UserListMember.where(user_list_id: primary_list_id, user_id: target_ids).pluck(:user_id).to_set :
      Set.new
    blocked_ids = UserBlock.blocked_pair_user_ids(viewer.id, target_ids)
    Result.new(on_list_ids: on_list_ids, blocked_pair_ids: blocked_ids)
  end
end
