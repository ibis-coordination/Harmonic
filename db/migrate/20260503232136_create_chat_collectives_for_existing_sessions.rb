class CreateChatCollectivesForExistingSessions < ActiveRecord::Migration[7.2]
  def up
    # For each existing chat session, create a dedicated chat collective
    # and move the session (and its messages) into it.
    execute <<~SQL
      DO $$
      DECLARE
        session RECORD;
        new_collective_id UUID;
      BEGIN
        FOR session IN
          SELECT cs.id, cs.tenant_id, cs.user_one_id, cs.user_two_id, cs.collective_id
          FROM chat_sessions cs
          -- Only migrate sessions still pointing to non-chat collectives
          WHERE cs.collective_id IN (
            SELECT id FROM collectives WHERE collective_type != 'chat'
          )
        LOOP
          -- Create a chat collective
          new_collective_id := gen_random_uuid();
          INSERT INTO collectives (
            id, tenant_id, name, handle, collective_type, billing_exempt,
            settings, created_by_id, updated_by_id, created_at, updated_at
          ) VALUES (
            new_collective_id,
            session.tenant_id,
            'Chat',
            encode(gen_random_bytes(8), 'hex'),
            'chat',
            true,
            '{"unlisted": true, "invite_only": true, "all_members_can_invite": false, "any_member_can_represent": false}'::jsonb,
            session.user_one_id,
            session.user_one_id,
            NOW(),
            NOW()
          );

          -- Add both participants as collective members
          INSERT INTO collective_members (id, tenant_id, collective_id, user_id, created_at, updated_at)
          VALUES (gen_random_uuid(), session.tenant_id, new_collective_id, session.user_one_id, NOW(), NOW());

          -- For self-chat sessions, don't add the same user twice
          IF session.user_one_id != session.user_two_id THEN
            INSERT INTO collective_members (id, tenant_id, collective_id, user_id, created_at, updated_at)
            VALUES (gen_random_uuid(), session.tenant_id, new_collective_id, session.user_two_id, NOW(), NOW());
          END IF;

          -- Update the chat session to point to the new collective
          UPDATE chat_sessions SET collective_id = new_collective_id WHERE id = session.id;

          -- Update all messages in this session to point to the new collective
          UPDATE chat_messages SET collective_id = new_collective_id WHERE chat_session_id = session.id;
        END LOOP;
      END $$;
    SQL
  end

  def down
    # Move chat sessions back to their tenant's main collective
    execute <<~SQL
      UPDATE chat_sessions cs
      SET collective_id = (
        SELECT t.main_collective_id FROM tenants t WHERE t.id = cs.tenant_id
      )
      WHERE cs.collective_id IN (
        SELECT id FROM collectives WHERE collective_type = 'chat'
      );

      UPDATE chat_messages cm
      SET collective_id = cs.collective_id
      FROM chat_sessions cs
      WHERE cm.chat_session_id = cs.id;

      -- Remove chat collective members
      DELETE FROM collective_members
      WHERE collective_id IN (SELECT id FROM collectives WHERE collective_type = 'chat');

      -- Remove chat collectives
      DELETE FROM collectives WHERE collective_type = 'chat';
    SQL
  end
end
