\restrict TYev7I9wCXBEfGm0ESmkaXkffv9Az0J03EaQb7Vo67xuiQgCHC717JUPd7wdacP

-- Dumped from database version 13.10 (Debian 13.10-1.pgdg110+1)
-- Dumped by pg_dump version 15.14 (Debian 15.14-0+deb12u1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id uuid NOT NULL,
    blob_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    blob_id uuid NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: api_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    name character varying,
    token character varying NOT NULL,
    last_used_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone DEFAULT (CURRENT_TIMESTAMP + '1 year'::interval),
    scopes jsonb DEFAULT '[]'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid NOT NULL,
    attachable_type character varying NOT NULL,
    attachable_id uuid NOT NULL,
    name character varying NOT NULL,
    content_type character varying NOT NULL,
    byte_size bigint NOT NULL,
    created_by_id uuid NOT NULL,
    updated_by_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: commitment_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commitment_participants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    commitment_id uuid NOT NULL,
    user_id uuid,
    participant_uid character varying DEFAULT ''::character varying NOT NULL,
    name character varying,
    committed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid
);


--
-- Name: commitments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commitments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text,
    description text,
    critical_mass integer,
    deadline timestamp(6) without time zone,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    studio_id uuid,
    "limit" integer
);


--
-- Name: cycle_data_commitments; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.cycle_data_commitments AS
SELECT
    NULL::uuid AS tenant_id,
    NULL::uuid AS studio_id,
    NULL::text AS item_type,
    NULL::uuid AS item_id,
    NULL::text AS title,
    NULL::timestamp(6) without time zone AS created_at,
    NULL::timestamp(6) without time zone AS updated_at,
    NULL::uuid AS created_by_id,
    NULL::uuid AS updated_by_id,
    NULL::timestamp(6) without time zone AS deadline,
    NULL::integer AS link_count,
    NULL::integer AS backlink_count,
    NULL::integer AS participant_count,
    NULL::integer AS voter_count,
    NULL::integer AS option_count;


--
-- Name: cycle_data_decisions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.cycle_data_decisions AS
SELECT
    NULL::uuid AS tenant_id,
    NULL::uuid AS studio_id,
    NULL::text AS item_type,
    NULL::uuid AS item_id,
    NULL::text AS title,
    NULL::timestamp(6) without time zone AS created_at,
    NULL::timestamp(6) without time zone AS updated_at,
    NULL::uuid AS created_by_id,
    NULL::uuid AS updated_by_id,
    NULL::timestamp(6) without time zone AS deadline,
    NULL::integer AS link_count,
    NULL::integer AS backlink_count,
    NULL::integer AS participant_count,
    NULL::integer AS voter_count,
    NULL::integer AS option_count;


--
-- Name: cycle_data_notes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.cycle_data_notes AS
SELECT
    NULL::uuid AS tenant_id,
    NULL::uuid AS studio_id,
    NULL::text AS item_type,
    NULL::uuid AS item_id,
    NULL::text AS title,
    NULL::timestamp(6) without time zone AS created_at,
    NULL::timestamp(6) without time zone AS updated_at,
    NULL::uuid AS created_by_id,
    NULL::uuid AS updated_by_id,
    NULL::timestamp(6) without time zone AS deadline,
    NULL::integer AS link_count,
    NULL::integer AS backlink_count,
    NULL::integer AS participant_count,
    NULL::integer AS voter_count,
    NULL::integer AS option_count;


--
-- Name: cycle_data; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.cycle_data AS
 SELECT n.tenant_id,
    n.studio_id,
    n.item_type,
    n.item_id,
    n.title,
    n.created_at,
    n.updated_at,
    n.created_by_id,
    n.updated_by_id,
    n.deadline,
    n.link_count,
    n.backlink_count,
    n.participant_count,
    n.voter_count,
    n.option_count
   FROM public.cycle_data_notes n
UNION ALL
 SELECT cycle_data_decisions.tenant_id,
    cycle_data_decisions.studio_id,
    cycle_data_decisions.item_type,
    cycle_data_decisions.item_id,
    cycle_data_decisions.title,
    cycle_data_decisions.created_at,
    cycle_data_decisions.updated_at,
    cycle_data_decisions.created_by_id,
    cycle_data_decisions.updated_by_id,
    cycle_data_decisions.deadline,
    cycle_data_decisions.link_count,
    cycle_data_decisions.backlink_count,
    cycle_data_decisions.participant_count,
    cycle_data_decisions.voter_count,
    cycle_data_decisions.option_count
   FROM public.cycle_data_decisions
UNION ALL
 SELECT cycle_data_commitments.tenant_id,
    cycle_data_commitments.studio_id,
    cycle_data_commitments.item_type,
    cycle_data_commitments.item_id,
    cycle_data_commitments.title,
    cycle_data_commitments.created_at,
    cycle_data_commitments.updated_at,
    cycle_data_commitments.created_by_id,
    cycle_data_commitments.updated_by_id,
    cycle_data_commitments.deadline,
    cycle_data_commitments.link_count,
    cycle_data_commitments.backlink_count,
    cycle_data_commitments.participant_count,
    cycle_data_commitments.voter_count,
    cycle_data_commitments.option_count
   FROM public.cycle_data_commitments
  ORDER BY 1, 2, 6 DESC;


--
-- Name: decision_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_participants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    decision_id uuid,
    name character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid,
    participant_uid character varying DEFAULT ''::character varying NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid
);


--
-- Name: decision_results; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.decision_results AS
SELECT
    NULL::uuid AS tenant_id,
    NULL::uuid AS decision_id,
    NULL::uuid AS option_id,
    NULL::text AS option_title,
    NULL::bigint AS accepted_yes,
    NULL::bigint AS accepted_no,
    NULL::bigint AS vote_count,
    NULL::bigint AS preferred,
    NULL::integer AS random_id;


--
-- Name: decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question text,
    description text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    deadline timestamp(6) without time zone,
    options_open boolean DEFAULT true NOT NULL,
    tenant_id uuid NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    studio_id uuid
);


--
-- Name: heartbeats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.heartbeats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid NOT NULL,
    user_id uuid NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    activity_log jsonb DEFAULT '{}'::jsonb NOT NULL,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    from_linkable_type character varying NOT NULL,
    from_linkable_id uuid NOT NULL,
    to_linkable_type character varying NOT NULL,
    to_linkable_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    studio_id uuid
);


--
-- Name: note_history_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.note_history_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    note_id uuid NOT NULL,
    user_id uuid,
    event_type character varying,
    happened_at timestamp without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid
);


--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text,
    text text,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    deadline timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by_id uuid,
    updated_by_id uuid,
    studio_id uuid,
    commentable_type character varying,
    commentable_id uuid
);


--
-- Name: oauth_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    provider character varying,
    uid character varying,
    last_sign_in_at timestamp(6) without time zone,
    url character varying,
    username character varying,
    image_url character varying,
    auth_data jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: omni_auth_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.omni_auth_identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying NOT NULL,
    name character varying,
    password_digest character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    reset_password_token character varying,
    reset_password_sent_at timestamp(6) without time zone
);


--
-- Name: options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    decision_id uuid,
    decision_participant_id uuid,
    title text NOT NULL,
    description text,
    random_id integer DEFAULT (floor((random() * (1000000000)::double precision)))::integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid
);


--
-- Name: representation_session_associations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.representation_session_associations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid NOT NULL,
    representation_session_id uuid NOT NULL,
    resource_type character varying NOT NULL,
    resource_id uuid NOT NULL,
    resource_studio_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: representation_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.representation_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid NOT NULL,
    representative_user_id uuid NOT NULL,
    trustee_user_id uuid NOT NULL,
    began_at timestamp(6) without time zone NOT NULL,
    ended_at timestamp(6) without time zone,
    confirmed_understanding boolean DEFAULT false NOT NULL,
    activity_log jsonb DEFAULT '{}'::jsonb,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: studio_invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.studio_invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid NOT NULL,
    created_by_id uuid NOT NULL,
    invited_user_id uuid,
    code character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: studio_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.studio_users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid NOT NULL,
    user_id uuid NOT NULL,
    archived_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb
);


--
-- Name: studios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.studios (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    name character varying,
    handle character varying,
    settings jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    created_by_id uuid NOT NULL,
    updated_by_id uuid NOT NULL,
    trustee_user_id uuid,
    description text,
    studio_type character varying DEFAULT 'studio'::character varying NOT NULL
);


--
-- Name: tenant_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    handle character varying NOT NULL,
    display_name character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    archived_at timestamp(6) without time zone
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subdomain character varying NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb,
    main_studio_id uuid,
    archived_at timestamp(6) without time zone
);


--
-- Name: trustee_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trustee_permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    trustee_user_id uuid NOT NULL,
    granting_user_id uuid NOT NULL,
    trusted_user_id uuid NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    relationship_phrase character varying DEFAULT '{trusted_user} on behalf of {granting_user}'::character varying NOT NULL,
    permissions jsonb DEFAULT '{}'::jsonb,
    expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying DEFAULT ''::character varying NOT NULL,
    name character varying DEFAULT ''::character varying NOT NULL,
    picture_url character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    image_url character varying,
    parent_id uuid,
    user_type character varying DEFAULT 'person'::character varying
);


--
-- Name: votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.votes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    decision_id uuid,
    decision_participant_id uuid,
    option_id uuid,
    accepted integer NOT NULL,
    preferred integer DEFAULT 0,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    studio_id uuid
);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: api_tokens api_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT api_tokens_pkey PRIMARY KEY (id);


--
-- Name: votes approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT approvals_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);


--
-- Name: commitment_participants commitment_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitment_participants
    ADD CONSTRAINT commitment_participants_pkey PRIMARY KEY (id);


--
-- Name: commitments commitments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitments
    ADD CONSTRAINT commitments_pkey PRIMARY KEY (id);


--
-- Name: decision_participants decision_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_participants
    ADD CONSTRAINT decision_participants_pkey PRIMARY KEY (id);


--
-- Name: decisions decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_pkey PRIMARY KEY (id);


--
-- Name: heartbeats heartbeats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeats
    ADD CONSTRAINT heartbeats_pkey PRIMARY KEY (id);


--
-- Name: links links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.links
    ADD CONSTRAINT links_pkey PRIMARY KEY (id);


--
-- Name: note_history_events note_history_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT note_history_events_pkey PRIMARY KEY (id);


--
-- Name: notes notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT notes_pkey PRIMARY KEY (id);


--
-- Name: oauth_identities oauth_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_identities
    ADD CONSTRAINT oauth_identities_pkey PRIMARY KEY (id);


--
-- Name: omni_auth_identities omni_auth_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.omni_auth_identities
    ADD CONSTRAINT omni_auth_identities_pkey PRIMARY KEY (id);


--
-- Name: options options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.options
    ADD CONSTRAINT options_pkey PRIMARY KEY (id);


--
-- Name: representation_session_associations representation_session_associations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_associations
    ADD CONSTRAINT representation_session_associations_pkey PRIMARY KEY (id);


--
-- Name: representation_sessions representation_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_sessions
    ADD CONSTRAINT representation_sessions_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: studio_invites studio_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_invites
    ADD CONSTRAINT studio_invites_pkey PRIMARY KEY (id);


--
-- Name: studio_users studio_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_users
    ADD CONSTRAINT studio_users_pkey PRIMARY KEY (id);


--
-- Name: studios studios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studios
    ADD CONSTRAINT studios_pkey PRIMARY KEY (id);


--
-- Name: tenant_users tenant_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_users
    ADD CONSTRAINT tenant_users_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: trustee_permissions trustee_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_permissions
    ADD CONSTRAINT trustee_permissions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_api_tokens_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_tenant_id ON public.api_tokens USING btree (tenant_id);


--
-- Name: index_api_tokens_on_tenant_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_tenant_id_and_user_id ON public.api_tokens USING btree (tenant_id, user_id);


--
-- Name: index_api_tokens_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_tokens_on_token ON public.api_tokens USING btree (token);


--
-- Name: index_api_tokens_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_user_id ON public.api_tokens USING btree (user_id);


--
-- Name: index_attachments_on_attachable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_attachable ON public.attachments USING btree (attachable_type, attachable_id);


--
-- Name: index_attachments_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_created_by_id ON public.attachments USING btree (created_by_id);


--
-- Name: index_attachments_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_studio_id ON public.attachments USING btree (studio_id);


--
-- Name: index_attachments_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_tenant_id ON public.attachments USING btree (tenant_id);


--
-- Name: index_attachments_on_tenant_studio_attachable_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_attachments_on_tenant_studio_attachable_name ON public.attachments USING btree (tenant_id, studio_id, attachable_id, name);


--
-- Name: index_attachments_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_updated_by_id ON public.attachments USING btree (updated_by_id);


--
-- Name: index_commitment_participants_on_commitment_and_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commitment_participants_on_commitment_and_uid ON public.commitment_participants USING btree (commitment_id, participant_uid);


--
-- Name: index_commitment_participants_on_commitment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_commitment_id ON public.commitment_participants USING btree (commitment_id);


--
-- Name: index_commitment_participants_on_participant_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_participant_uid ON public.commitment_participants USING btree (participant_uid);


--
-- Name: index_commitment_participants_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_studio_id ON public.commitment_participants USING btree (studio_id);


--
-- Name: index_commitment_participants_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_tenant_id ON public.commitment_participants USING btree (tenant_id);


--
-- Name: index_commitment_participants_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_user_id ON public.commitment_participants USING btree (user_id);


--
-- Name: index_commitments_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitments_on_created_by_id ON public.commitments USING btree (created_by_id);


--
-- Name: index_commitments_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitments_on_studio_id ON public.commitments USING btree (studio_id);


--
-- Name: index_commitments_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitments_on_tenant_id ON public.commitments USING btree (tenant_id);


--
-- Name: index_commitments_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commitments_on_truncated_id ON public.commitments USING btree (truncated_id);


--
-- Name: index_commitments_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitments_on_updated_by_id ON public.commitments USING btree (updated_by_id);


--
-- Name: index_decision_participants_on_decision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_participants_on_decision_id ON public.decision_participants USING btree (decision_id);


--
-- Name: index_decision_participants_on_decision_id_and_participant_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_decision_participants_on_decision_id_and_participant_uid ON public.decision_participants USING btree (decision_id, participant_uid);


--
-- Name: index_decision_participants_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_participants_on_studio_id ON public.decision_participants USING btree (studio_id);


--
-- Name: index_decision_participants_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_participants_on_tenant_id ON public.decision_participants USING btree (tenant_id);


--
-- Name: index_decisions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decisions_on_created_by_id ON public.decisions USING btree (created_by_id);


--
-- Name: index_decisions_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decisions_on_studio_id ON public.decisions USING btree (studio_id);


--
-- Name: index_decisions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decisions_on_tenant_id ON public.decisions USING btree (tenant_id);


--
-- Name: index_decisions_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_decisions_on_truncated_id ON public.decisions USING btree (truncated_id);


--
-- Name: index_decisions_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decisions_on_updated_by_id ON public.decisions USING btree (updated_by_id);


--
-- Name: index_heartbeats_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_heartbeats_on_studio_id ON public.heartbeats USING btree (studio_id);


--
-- Name: index_heartbeats_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_heartbeats_on_tenant_id ON public.heartbeats USING btree (tenant_id);


--
-- Name: index_heartbeats_on_tenant_studio_user_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_heartbeats_on_tenant_studio_user_expires_at ON public.heartbeats USING btree (tenant_id, studio_id, user_id, expires_at);


--
-- Name: index_heartbeats_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_heartbeats_on_truncated_id ON public.heartbeats USING btree (truncated_id);


--
-- Name: index_heartbeats_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_heartbeats_on_user_id ON public.heartbeats USING btree (user_id);


--
-- Name: index_links_on_from_linkable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_from_linkable ON public.links USING btree (from_linkable_type, from_linkable_id);


--
-- Name: index_links_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_studio_id ON public.links USING btree (studio_id);


--
-- Name: index_links_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_tenant_id ON public.links USING btree (tenant_id);


--
-- Name: index_links_on_to_linkable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_to_linkable ON public.links USING btree (to_linkable_type, to_linkable_id);


--
-- Name: index_note_history_events_on_note_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_note_id ON public.note_history_events USING btree (note_id);


--
-- Name: index_note_history_events_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_studio_id ON public.note_history_events USING btree (studio_id);


--
-- Name: index_note_history_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_tenant_id ON public.note_history_events USING btree (tenant_id);


--
-- Name: index_note_history_events_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_user_id ON public.note_history_events USING btree (user_id);


--
-- Name: index_notes_on_commentable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_commentable ON public.notes USING btree (commentable_type, commentable_id);


--
-- Name: index_notes_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_created_by_id ON public.notes USING btree (created_by_id);


--
-- Name: index_notes_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_studio_id ON public.notes USING btree (studio_id);


--
-- Name: index_notes_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_tenant_id ON public.notes USING btree (tenant_id);


--
-- Name: index_notes_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notes_on_truncated_id ON public.notes USING btree (truncated_id);


--
-- Name: index_notes_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_updated_by_id ON public.notes USING btree (updated_by_id);


--
-- Name: index_oauth_identities_on_provider_and_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_oauth_identities_on_provider_and_uid ON public.oauth_identities USING btree (provider, uid);


--
-- Name: index_oauth_identities_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_oauth_identities_on_user_id ON public.oauth_identities USING btree (user_id);


--
-- Name: index_omni_auth_identities_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_omni_auth_identities_on_email ON public.omni_auth_identities USING btree (email);


--
-- Name: index_omni_auth_identities_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_omni_auth_identities_on_reset_password_token ON public.omni_auth_identities USING btree (reset_password_token);


--
-- Name: index_options_on_decision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_options_on_decision_id ON public.options USING btree (decision_id);


--
-- Name: index_options_on_decision_id_and_title; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_options_on_decision_id_and_title ON public.options USING btree (decision_id, title);


--
-- Name: index_options_on_decision_participant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_options_on_decision_participant_id ON public.options USING btree (decision_participant_id);


--
-- Name: index_options_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_options_on_studio_id ON public.options USING btree (studio_id);


--
-- Name: index_options_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_options_on_tenant_id ON public.options USING btree (tenant_id);


--
-- Name: index_rep_session_assoc_on_rep_session_and_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_rep_session_assoc_on_rep_session_and_resource ON public.representation_session_associations USING btree (representation_session_id, resource_id, resource_type);


--
-- Name: index_rep_session_assoc_on_rep_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rep_session_assoc_on_rep_session_id ON public.representation_session_associations USING btree (representation_session_id);


--
-- Name: index_rep_session_assoc_on_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rep_session_assoc_on_resource ON public.representation_session_associations USING btree (resource_type, resource_id);


--
-- Name: index_rep_session_assoc_on_resource_studio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rep_session_assoc_on_resource_studio ON public.representation_session_associations USING btree (resource_studio_id);


--
-- Name: index_representation_session_associations_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_session_associations_on_studio_id ON public.representation_session_associations USING btree (studio_id);


--
-- Name: index_representation_session_associations_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_session_associations_on_tenant_id ON public.representation_session_associations USING btree (tenant_id);


--
-- Name: index_representation_sessions_on_representative_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_representative_user_id ON public.representation_sessions USING btree (representative_user_id);


--
-- Name: index_representation_sessions_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_studio_id ON public.representation_sessions USING btree (studio_id);


--
-- Name: index_representation_sessions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_tenant_id ON public.representation_sessions USING btree (tenant_id);


--
-- Name: index_representation_sessions_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_representation_sessions_on_truncated_id ON public.representation_sessions USING btree (truncated_id);


--
-- Name: index_representation_sessions_on_trustee_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_trustee_user_id ON public.representation_sessions USING btree (trustee_user_id);


--
-- Name: index_studio_invites_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_studio_invites_on_code ON public.studio_invites USING btree (code);


--
-- Name: index_studio_invites_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studio_invites_on_created_by_id ON public.studio_invites USING btree (created_by_id);


--
-- Name: index_studio_invites_on_invited_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studio_invites_on_invited_user_id ON public.studio_invites USING btree (invited_user_id);


--
-- Name: index_studio_invites_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studio_invites_on_studio_id ON public.studio_invites USING btree (studio_id);


--
-- Name: index_studio_invites_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studio_invites_on_tenant_id ON public.studio_invites USING btree (tenant_id);


--
-- Name: index_studio_users_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studio_users_on_studio_id ON public.studio_users USING btree (studio_id);


--
-- Name: index_studio_users_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studio_users_on_tenant_id ON public.studio_users USING btree (tenant_id);


--
-- Name: index_studio_users_on_tenant_id_and_studio_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_studio_users_on_tenant_id_and_studio_id_and_user_id ON public.studio_users USING btree (tenant_id, studio_id, user_id);


--
-- Name: index_studio_users_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studio_users_on_user_id ON public.studio_users USING btree (user_id);


--
-- Name: index_studios_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studios_on_created_by_id ON public.studios USING btree (created_by_id);


--
-- Name: index_studios_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studios_on_tenant_id ON public.studios USING btree (tenant_id);


--
-- Name: index_studios_on_tenant_id_and_handle; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_studios_on_tenant_id_and_handle ON public.studios USING btree (tenant_id, handle);


--
-- Name: index_studios_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_studios_on_updated_by_id ON public.studios USING btree (updated_by_id);


--
-- Name: index_tenant_users_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tenant_users_on_tenant_id ON public.tenant_users USING btree (tenant_id);


--
-- Name: index_tenant_users_on_tenant_id_and_handle; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenant_users_on_tenant_id_and_handle ON public.tenant_users USING btree (tenant_id, handle);


--
-- Name: index_tenant_users_on_tenant_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenant_users_on_tenant_id_and_user_id ON public.tenant_users USING btree (tenant_id, user_id);


--
-- Name: index_tenant_users_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tenant_users_on_user_id ON public.tenant_users USING btree (user_id);


--
-- Name: index_tenants_on_main_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tenants_on_main_studio_id ON public.tenants USING btree (main_studio_id);


--
-- Name: index_tenants_on_subdomain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_subdomain ON public.tenants USING btree (subdomain);


--
-- Name: index_trustee_permissions_on_granting_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trustee_permissions_on_granting_user_id ON public.trustee_permissions USING btree (granting_user_id);


--
-- Name: index_trustee_permissions_on_trusted_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trustee_permissions_on_trusted_user_id ON public.trustee_permissions USING btree (trusted_user_id);


--
-- Name: index_trustee_permissions_on_trustee_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trustee_permissions_on_trustee_user_id ON public.trustee_permissions USING btree (trustee_user_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_parent_id ON public.users USING btree (parent_id);


--
-- Name: index_votes_on_decision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_votes_on_decision_id ON public.votes USING btree (decision_id);


--
-- Name: index_votes_on_decision_participant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_votes_on_decision_participant_id ON public.votes USING btree (decision_participant_id);


--
-- Name: index_votes_on_option_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_votes_on_option_id ON public.votes USING btree (option_id);


--
-- Name: index_votes_on_option_id_and_decision_participant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_votes_on_option_id_and_decision_participant_id ON public.votes USING btree (option_id, decision_participant_id);


--
-- Name: index_votes_on_studio_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_votes_on_studio_id ON public.votes USING btree (studio_id);


--
-- Name: index_votes_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_votes_on_tenant_id ON public.votes USING btree (tenant_id);


--
-- Name: cycle_data_commitments _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.cycle_data_commitments AS
 SELECT c.tenant_id,
    c.studio_id,
    'Commitment'::text AS item_type,
    c.id AS item_id,
    c.title,
    c.created_at,
    c.updated_at,
    c.created_by_id,
    c.updated_by_id,
    c.deadline,
    (count(DISTINCT cl.id))::integer AS link_count,
    (count(DISTINCT cbl.id))::integer AS backlink_count,
    (count(DISTINCT p.user_id))::integer AS participant_count,
    NULL::integer AS voter_count,
    NULL::integer AS option_count
   FROM (((public.commitments c
     LEFT JOIN public.commitment_participants p ON ((c.id = p.commitment_id)))
     LEFT JOIN public.links cl ON (((c.id = cl.from_linkable_id) AND ((cl.from_linkable_type)::text = 'Commitment'::text))))
     LEFT JOIN public.links cbl ON (((c.id = cbl.to_linkable_id) AND ((cbl.to_linkable_type)::text = 'Commitment'::text))))
  GROUP BY c.tenant_id, c.studio_id, c.id
  ORDER BY c.tenant_id, c.studio_id, c.created_at DESC;


--
-- Name: cycle_data_decisions _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.cycle_data_decisions AS
 SELECT d.tenant_id,
    d.studio_id,
    'Decision'::text AS item_type,
    d.id AS item_id,
    d.question AS title,
    d.created_at,
    d.updated_at,
    d.created_by_id,
    d.updated_by_id,
    d.deadline,
    (count(DISTINCT dl.id))::integer AS link_count,
    (count(DISTINCT dbl.id))::integer AS backlink_count,
    (count(DISTINCT a.decision_participant_id))::integer AS participant_count,
    (count(DISTINCT a.decision_participant_id))::integer AS voter_count,
    (count(DISTINCT o.id))::integer AS option_count
   FROM ((((public.decisions d
     LEFT JOIN public.votes a ON ((d.id = a.decision_id)))
     LEFT JOIN public.options o ON ((d.id = o.decision_id)))
     LEFT JOIN public.links dl ON (((d.id = dl.from_linkable_id) AND ((dl.from_linkable_type)::text = 'Decision'::text))))
     LEFT JOIN public.links dbl ON (((d.id = dbl.to_linkable_id) AND ((dbl.to_linkable_type)::text = 'Decision'::text))))
  GROUP BY d.tenant_id, d.studio_id, d.id
  ORDER BY d.tenant_id, d.studio_id, d.created_at DESC;


--
-- Name: cycle_data_notes _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.cycle_data_notes AS
 SELECT n.tenant_id,
    n.studio_id,
    'Note'::text AS item_type,
    n.id AS item_id,
    n.title,
    n.created_at,
    n.updated_at,
    n.created_by_id,
    n.updated_by_id,
    n.deadline,
    (count(DISTINCT nl.id))::integer AS link_count,
    (count(DISTINCT nbl.id))::integer AS backlink_count,
    (count(DISTINCT nhe.user_id))::integer AS participant_count,
    NULL::integer AS voter_count,
    NULL::integer AS option_count
   FROM (((public.notes n
     LEFT JOIN public.note_history_events nhe ON (((n.id = nhe.note_id) AND ((nhe.event_type)::text = 'confirmed_read'::text))))
     LEFT JOIN public.links nl ON (((n.id = nl.from_linkable_id) AND ((nl.from_linkable_type)::text = 'Note'::text))))
     LEFT JOIN public.links nbl ON (((n.id = nbl.to_linkable_id) AND ((nbl.to_linkable_type)::text = 'Note'::text))))
  GROUP BY n.tenant_id, n.studio_id, n.id
  ORDER BY n.tenant_id, n.studio_id, n.created_at DESC;


--
-- Name: decision_results _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.decision_results AS
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


--
-- Name: studio_invites fk_rails_07e7bb098b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_invites
    ADD CONSTRAINT fk_rails_07e7bb098b FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: note_history_events fk_rails_0a4621d4f9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT fk_rails_0a4621d4f9 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: votes fk_rails_0e623a5b8b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT fk_rails_0e623a5b8b FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: options fk_rails_129a008786; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.options
    ADD CONSTRAINT fk_rails_129a008786 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: decisions fk_rails_148841bc6d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT fk_rails_148841bc6d FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: studio_invites fk_rails_19f2570176; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_invites
    ADD CONSTRAINT fk_rails_19f2570176 FOREIGN KEY (invited_user_id) REFERENCES public.users(id);


--
-- Name: votes fk_rails_23f31e4409; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT fk_rails_23f31e4409 FOREIGN KEY (option_id) REFERENCES public.options(id);


--
-- Name: studio_users fk_rails_247e24a571; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_users
    ADD CONSTRAINT fk_rails_247e24a571 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: studio_invites fk_rails_29373b6d24; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_invites
    ADD CONSTRAINT fk_rails_29373b6d24 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: representation_session_associations fk_rails_2959985639; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_associations
    ADD CONSTRAINT fk_rails_2959985639 FOREIGN KEY (resource_studio_id) REFERENCES public.studios(id);


--
-- Name: commitments fk_rails_2b0260c142; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitments
    ADD CONSTRAINT fk_rails_2b0260c142 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: oauth_identities fk_rails_2f75762ff1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_identities
    ADD CONSTRAINT fk_rails_2f75762ff1 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: decision_participants fk_rails_2fac9cdcc1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_participants
    ADD CONSTRAINT fk_rails_2fac9cdcc1 FOREIGN KEY (decision_id) REFERENCES public.decisions(id);


--
-- Name: representation_sessions fk_rails_33f2d734e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_sessions
    ADD CONSTRAINT fk_rails_33f2d734e7 FOREIGN KEY (representative_user_id) REFERENCES public.users(id);


--
-- Name: decisions fk_rails_3844b64911; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT fk_rails_3844b64911 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: votes fk_rails_387fb9c532; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT fk_rails_387fb9c532 FOREIGN KEY (decision_id) REFERENCES public.decisions(id);


--
-- Name: attachments fk_rails_39994d8597; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT fk_rails_39994d8597 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: studios fk_rails_3a6c376636; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studios
    ADD CONSTRAINT fk_rails_3a6c376636 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: options fk_rails_3c650690de; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.options
    ADD CONSTRAINT fk_rails_3c650690de FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: commitment_participants fk_rails_40630ce2d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitment_participants
    ADD CONSTRAINT fk_rails_40630ce2d2 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: notes fk_rails_492bbd23f7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT fk_rails_492bbd23f7 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: commitments fk_rails_4bd2b4721e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitments
    ADD CONSTRAINT fk_rails_4bd2b4721e FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: studio_users fk_rails_55c1625b39; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_users
    ADD CONSTRAINT fk_rails_55c1625b39 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: representation_session_associations fk_rails_57828aec4a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_associations
    ADD CONSTRAINT fk_rails_57828aec4a FOREIGN KEY (representation_session_id) REFERENCES public.representation_sessions(id);


--
-- Name: note_history_events fk_rails_601d54357c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT fk_rails_601d54357c FOREIGN KEY (note_id) REFERENCES public.notes(id);


--
-- Name: trustee_permissions fk_rails_61c22cd494; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_permissions
    ADD CONSTRAINT fk_rails_61c22cd494 FOREIGN KEY (trusted_user_id) REFERENCES public.users(id);


--
-- Name: note_history_events fk_rails_63e2a8744d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT fk_rails_63e2a8744d FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: heartbeats fk_rails_65aa64ba75; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeats
    ADD CONSTRAINT fk_rails_65aa64ba75 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: links fk_rails_6888b30c51; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.links
    ADD CONSTRAINT fk_rails_6888b30c51 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: studio_users fk_rails_6922fe428a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_users
    ADD CONSTRAINT fk_rails_6922fe428a FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: studio_invites fk_rails_6dd1026bef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studio_invites
    ADD CONSTRAINT fk_rails_6dd1026bef FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: notes fk_rails_6e1963e950; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT fk_rails_6e1963e950 FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: decisions fk_rails_7ee5cf7c37; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT fk_rails_7ee5cf7c37 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: tenants fk_rails_81228c3d0f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT fk_rails_81228c3d0f FOREIGN KEY (main_studio_id) REFERENCES public.studios(id);


--
-- Name: decision_participants fk_rails_81ebc9cc6f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_participants
    ADD CONSTRAINT fk_rails_81ebc9cc6f FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: attachments fk_rails_87cce8e128; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT fk_rails_87cce8e128 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: trustee_permissions fk_rails_8bee20bb10; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_permissions
    ADD CONSTRAINT fk_rails_8bee20bb10 FOREIGN KEY (trustee_user_id) REFERENCES public.users(id);


--
-- Name: studios fk_rails_8d8050599b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studios
    ADD CONSTRAINT fk_rails_8d8050599b FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: representation_session_associations fk_rails_9127d7fed8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_associations
    ADD CONSTRAINT fk_rails_9127d7fed8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: note_history_events fk_rails_927b722124; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT fk_rails_927b722124 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: options fk_rails_9d942eefce; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.options
    ADD CONSTRAINT fk_rails_9d942eefce FOREIGN KEY (decision_participant_id) REFERENCES public.decision_participants(id);


--
-- Name: votes fk_rails_a6ed1157e1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT fk_rails_a6ed1157e1 FOREIGN KEY (decision_participant_id) REFERENCES public.decision_participants(id);


--
-- Name: attachments fk_rails_a7d5052ac1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT fk_rails_a7d5052ac1 FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: commitments fk_rails_ae61a497df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitments
    ADD CONSTRAINT fk_rails_ae61a497df FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: votes fk_rails_ae9f41675e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT fk_rails_ae9f41675e FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: heartbeats fk_rails_c4c1ea3d5d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeats
    ADD CONSTRAINT fk_rails_c4c1ea3d5d FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: commitment_participants fk_rails_ca2dcc834c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitment_participants
    ADD CONSTRAINT fk_rails_ca2dcc834c FOREIGN KEY (commitment_id) REFERENCES public.commitments(id);


--
-- Name: attachments fk_rails_ca54061570; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT fk_rails_ca54061570 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: links fk_rails_cd7c2a63d7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.links
    ADD CONSTRAINT fk_rails_cd7c2a63d7 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: api_tokens fk_rails_ce1100e505; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT fk_rails_ce1100e505 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: representation_session_associations fk_rails_d26514fc52; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_associations
    ADD CONSTRAINT fk_rails_d26514fc52 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: representation_sessions fk_rails_d99c283120; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_sessions
    ADD CONSTRAINT fk_rails_d99c283120 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: decisions fk_rails_db126ea214; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT fk_rails_db126ea214 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: representation_sessions fk_rails_db6c6b2118; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_sessions
    ADD CONSTRAINT fk_rails_db6c6b2118 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: trustee_permissions fk_rails_dc3eb15db3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_permissions
    ADD CONSTRAINT fk_rails_dc3eb15db3 FOREIGN KEY (granting_user_id) REFERENCES public.users(id);


--
-- Name: options fk_rails_df3bc80da2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.options
    ADD CONSTRAINT fk_rails_df3bc80da2 FOREIGN KEY (decision_id) REFERENCES public.decisions(id);


--
-- Name: tenant_users fk_rails_e15916f8bf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_users
    ADD CONSTRAINT fk_rails_e15916f8bf FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: tenant_users fk_rails_e3b237e564; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_users
    ADD CONSTRAINT fk_rails_e3b237e564 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: notes fk_rails_e420fccb7e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT fk_rails_e420fccb7e FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: commitments fk_rails_e4837f1e6d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitments
    ADD CONSTRAINT fk_rails_e4837f1e6d FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: representation_sessions fk_rails_ee2c2c283c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_sessions
    ADD CONSTRAINT fk_rails_ee2c2c283c FOREIGN KEY (trustee_user_id) REFERENCES public.users(id);


--
-- Name: heartbeats fk_rails_ef017bd5f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeats
    ADD CONSTRAINT fk_rails_ef017bd5f0 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: decision_participants fk_rails_ef2bebed7c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_participants
    ADD CONSTRAINT fk_rails_ef2bebed7c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: commitment_participants fk_rails_f0bea833a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitment_participants
    ADD CONSTRAINT fk_rails_f0bea833a7 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: notes fk_rails_f11a0907b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT fk_rails_f11a0907b0 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: api_tokens fk_rails_f16b5e0447; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT fk_rails_f16b5e0447 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: commitment_participants fk_rails_f513f0d5dd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitment_participants
    ADD CONSTRAINT fk_rails_f513f0d5dd FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: decision_participants fk_rails_f9c15d4765; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_participants
    ADD CONSTRAINT fk_rails_f9c15d4765 FOREIGN KEY (studio_id) REFERENCES public.studios(id);


--
-- Name: studios fk_rails_fbb5f3e2b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.studios
    ADD CONSTRAINT fk_rails_fbb5f3e2b8 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

\unrestrict TYev7I9wCXBEfGm0ESmkaXkffv9Az0J03EaQb7Vo67xuiQgCHC717JUPd7wdacP

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20230325020222'),
('20230325020226'),
('20230325205117'),
('20230325231457'),
('20230325231507'),
('20230325231519'),
('20230325231529'),
('20230325231541'),
('20230325231549'),
('20230328030056'),
('20230329005723'),
('20230402225200'),
('20230405011057'),
('20230406011007'),
('20230408031436'),
('20230411232043'),
('20230411232223'),
('20230412040616'),
('20230412041938'),
('20230412044504'),
('20230415035625'),
('20230416044353'),
('20230416224308'),
('20230507175029'),
('20230507185725'),
('20230507200305'),
('20230507202114'),
('20230514003758'),
('20230514234410'),
('20230520210702'),
('20230520210703'),
('20230520211339'),
('20230524032233'),
('20230619223228'),
('20230808204725'),
('20230810195248'),
('20230811224634'),
('20230811232138'),
('20230812051757'),
('20230826212206'),
('20230827183501'),
('20230827190826'),
('20230908024626'),
('20230913025720'),
('20231005010534'),
('20241003023146'),
('20241012185630'),
('20241108202425'),
('20241110205225'),
('20241112212624'),
('20241112214416'),
('20241115022429'),
('20241119182930'),
('20241120025254'),
('20241120183533'),
('20241123230912'),
('20241124001646'),
('20241125235008'),
('20241126215856'),
('20241127005322'),
('20241127011437'),
('20241127174032'),
('20241128041104'),
('20241128054723'),
('20241128204415'),
('20241130040434'),
('20241130211736'),
('20241203033229'),
('20241204200412'),
('20241205180447'),
('20241205223939'),
('20241205225353'),
('20241206195305'),
('20241207193204'),
('20241209070422'),
('20241209163149'),
('20241212161322'),
('20241212193700'),
('20241214222145'),
('20250420173702'),
('20250421210507'),
('20250421210906'),
('20250421211106'),
('20250813231547'),
('20250815005326'),
('20250818184030'),
('20250819213059'),
('20250826214040'),
('20250831231336'),
('20250902174420'),
('20260109023653'),
('20260110023045');


