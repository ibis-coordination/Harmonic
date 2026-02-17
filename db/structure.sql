\restrict guCJPruAdnheuOfGgbG1Ga41uSKeX6dLG3fgtXWDem9t4WsW46OnjNlhdEHYj8p

-- Dumped from database version 13.10 (Debian 13.10-1.pgdg110+1)
-- Dumped by pg_dump version 15.16 (Debian 15.16-0+deb12u1)

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
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


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
-- Name: ai_agent_task_run_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_agent_task_run_resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    ai_agent_task_run_id uuid NOT NULL,
    resource_type character varying NOT NULL,
    resource_id uuid NOT NULL,
    resource_collective_id uuid NOT NULL,
    action_type character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    display_path character varying
);


--
-- Name: ai_agent_task_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_agent_task_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    ai_agent_id uuid NOT NULL,
    initiated_by_id uuid NOT NULL,
    task text NOT NULL,
    max_steps integer DEFAULT 30 NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    success boolean,
    final_message text,
    error text,
    steps_count integer DEFAULT 0,
    steps_data jsonb DEFAULT '[]'::jsonb,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    model character varying,
    input_tokens integer DEFAULT 0,
    output_tokens integer DEFAULT 0,
    total_tokens integer DEFAULT 0,
    estimated_cost_usd numeric(10,6),
    automation_rule_id uuid
);


--
-- Name: api_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    name character varying,
    last_used_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone DEFAULT (CURRENT_TIMESTAMP + '1 year'::interval),
    scopes jsonb DEFAULT '[]'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone,
    sys_admin boolean DEFAULT false NOT NULL,
    app_admin boolean DEFAULT false NOT NULL,
    tenant_admin boolean DEFAULT false NOT NULL,
    token_hash character varying,
    token_prefix character varying(4),
    internal boolean DEFAULT false NOT NULL
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
    collective_id uuid NOT NULL,
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
-- Name: automation_rule_run_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automation_rule_run_resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    automation_rule_run_id uuid NOT NULL,
    resource_type character varying NOT NULL,
    resource_id uuid NOT NULL,
    resource_collective_id uuid NOT NULL,
    action_type character varying,
    display_path character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: automation_rule_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automation_rule_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    automation_rule_id uuid NOT NULL,
    triggered_by_event_id uuid,
    ai_agent_task_run_id uuid,
    trigger_source character varying,
    trigger_data jsonb DEFAULT '{}'::jsonb,
    status character varying DEFAULT 'pending'::character varying,
    actions_executed jsonb DEFAULT '[]'::jsonb,
    error_message text,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    collective_id uuid,
    chain_metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: automation_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automation_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid,
    user_id uuid,
    ai_agent_id uuid,
    created_by_id uuid NOT NULL,
    name character varying NOT NULL,
    description text,
    trigger_type character varying NOT NULL,
    trigger_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    conditions jsonb DEFAULT '[]'::jsonb NOT NULL,
    actions jsonb DEFAULT '[]'::jsonb NOT NULL,
    yaml_source text,
    enabled boolean DEFAULT true NOT NULL,
    execution_count integer DEFAULT 0 NOT NULL,
    last_executed_at timestamp(6) without time zone,
    webhook_secret character varying,
    webhook_path character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    updated_by_id uuid
);


--
-- Name: collective_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collective_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    user_id uuid NOT NULL,
    archived_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb
);


--
-- Name: collectives; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collectives (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    name character varying,
    handle character varying,
    settings jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    created_by_id uuid NOT NULL,
    updated_by_id uuid NOT NULL,
    proxy_user_id uuid,
    description text,
    collective_type character varying DEFAULT 'studio'::character varying NOT NULL,
    internal boolean DEFAULT false NOT NULL
);


--
-- Name: commitment_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commitment_participants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    commitment_id uuid NOT NULL,
    user_id uuid,
    participant_uid character varying DEFAULT ''::character varying NOT NULL,
    committed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid
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
    collective_id uuid,
    "limit" integer
);


--
-- Name: cycle_data_commitments; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.cycle_data_commitments AS
SELECT
    NULL::uuid AS tenant_id,
    NULL::uuid AS collective_id,
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
    NULL::uuid AS collective_id,
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
    NULL::uuid AS collective_id,
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
 SELECT cycle_data_notes.tenant_id,
    cycle_data_notes.collective_id,
    cycle_data_notes.item_type,
    cycle_data_notes.item_id,
    cycle_data_notes.title,
    cycle_data_notes.created_at,
    cycle_data_notes.updated_at,
    cycle_data_notes.created_by_id,
    cycle_data_notes.updated_by_id,
    cycle_data_notes.deadline,
    cycle_data_notes.link_count,
    cycle_data_notes.backlink_count,
    cycle_data_notes.participant_count,
    cycle_data_notes.voter_count,
    cycle_data_notes.option_count
   FROM public.cycle_data_notes
UNION ALL
 SELECT cycle_data_decisions.tenant_id,
    cycle_data_decisions.collective_id,
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
    cycle_data_commitments.collective_id,
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
   FROM public.cycle_data_commitments;


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
    collective_id uuid
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
    collective_id uuid
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    event_type character varying NOT NULL,
    actor_id uuid,
    subject_type character varying,
    subject_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: heartbeats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.heartbeats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    user_id uuid NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    activity_log jsonb DEFAULT '{}'::jsonb NOT NULL,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    created_by_id uuid NOT NULL,
    invited_user_id uuid,
    code character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
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
    collective_id uuid
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
    collective_id uuid
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
    collective_id uuid,
    commentable_type character varying,
    commentable_id uuid
);


--
-- Name: notification_recipients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_recipients (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    notification_id uuid NOT NULL,
    user_id uuid NOT NULL,
    channel character varying DEFAULT 'in_app'::character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    read_at timestamp(6) without time zone,
    dismissed_at timestamp(6) without time zone,
    delivered_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    scheduled_for timestamp(6) without time zone,
    tenant_id uuid NOT NULL
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid,
    tenant_id uuid NOT NULL,
    notification_type character varying NOT NULL,
    title character varying NOT NULL,
    body text,
    url character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
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
    reset_password_sent_at timestamp(6) without time zone,
    otp_secret character varying,
    otp_enabled boolean DEFAULT false NOT NULL,
    otp_enabled_at timestamp(6) without time zone,
    otp_recovery_codes jsonb DEFAULT '[]'::jsonb,
    otp_failed_attempts integer DEFAULT 0 NOT NULL,
    otp_locked_until timestamp(6) without time zone
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
    collective_id uuid
);


--
-- Name: representation_session_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.representation_session_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid,
    representation_session_id uuid NOT NULL,
    action_name character varying NOT NULL,
    resource_type character varying NOT NULL,
    resource_id uuid NOT NULL,
    context_resource_type character varying,
    context_resource_id uuid,
    resource_collective_id uuid NOT NULL,
    request_id character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: representation_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.representation_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid,
    representative_user_id uuid NOT NULL,
    began_at timestamp(6) without time zone NOT NULL,
    ended_at timestamp(6) without time zone,
    confirmed_understanding boolean DEFAULT false NOT NULL,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    trustee_grant_id uuid
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: search_index; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint NOT NULL,
    subtype character varying,
    replying_to_id uuid
)
PARTITION BY HASH (tenant_id);


--
-- Name: search_index_sort_key_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.search_index_sort_key_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: search_index_sort_key_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.search_index_sort_key_seq OWNED BY public.search_index.sort_key;


--
-- Name: search_index_p0; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p0 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p1 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p10 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p11 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p12; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p12 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p13; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p13 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p14; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p14 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p15; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p15 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p2 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p3 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p4 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p5; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p5 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p6; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p6 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p7; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p7 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p8; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p8 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
);


--
-- Name: search_index_p9; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_index_p9 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    collective_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    truncated_id character varying(8) NOT NULL,
    title text NOT NULL,
    body text,
    searchable_text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deadline timestamp(6) without time zone NOT NULL,
    created_by_id uuid,
    updated_by_id uuid,
    link_count integer DEFAULT 0,
    backlink_count integer DEFAULT 0,
    participant_count integer DEFAULT 0,
    voter_count integer DEFAULT 0,
    option_count integer DEFAULT 0,
    comment_count integer DEFAULT 0,
    reader_count integer DEFAULT 0,
    is_pinned boolean DEFAULT false,
    sort_key bigint DEFAULT nextval('public.search_index_sort_key_seq'::regclass) NOT NULL,
    subtype character varying,
    replying_to_id uuid
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
    main_collective_id uuid,
    archived_at timestamp(6) without time zone,
    suspended_at timestamp(6) without time zone,
    suspended_reason character varying
);


--
-- Name: trustee_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trustee_grants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    granting_user_id uuid NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    permissions jsonb DEFAULT '{}'::jsonb,
    expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid,
    accepted_at timestamp(6) without time zone,
    declined_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    studio_scope jsonb DEFAULT '{"mode": "all"}'::jsonb,
    truncated_id character varying GENERATED ALWAYS AS ("left"((id)::text, 8)) STORED NOT NULL,
    trustee_user_id uuid NOT NULL
);


--
-- Name: user_item_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
)
PARTITION BY HASH (tenant_id);


--
-- Name: user_item_status_p0; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p0 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p1 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p10 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p11 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p12; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p12 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p13; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p13 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p14; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p14 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p15; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p15 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p2 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p3 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p4 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p5; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p5 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p6; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p6 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p7; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p7 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p8; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p8 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
);


--
-- Name: user_item_status_p9; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_item_status_p9 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying NOT NULL,
    item_id uuid NOT NULL,
    has_read boolean DEFAULT false,
    read_at timestamp(6) without time zone,
    has_voted boolean DEFAULT false,
    voted_at timestamp(6) without time zone,
    is_participating boolean DEFAULT false,
    participated_at timestamp(6) without time zone,
    is_creator boolean DEFAULT false,
    last_viewed_at timestamp(6) without time zone,
    is_mentioned boolean DEFAULT false
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
    user_type character varying DEFAULT 'human'::character varying,
    app_admin boolean DEFAULT false NOT NULL,
    sys_admin boolean DEFAULT false NOT NULL,
    suspended_at timestamp(6) without time zone,
    suspended_by_id uuid,
    suspended_reason character varying,
    agent_configuration jsonb DEFAULT '{}'::jsonb
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
    collective_id uuid
);


--
-- Name: webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    request_body text,
    response_code integer,
    response_body text,
    error_message text,
    delivered_at timestamp(6) without time zone,
    next_retry_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    automation_rule_run_id uuid,
    url character varying,
    secret character varying
);


--
-- Name: search_index_p0; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p0 FOR VALUES WITH (modulus 16, remainder 0);


--
-- Name: search_index_p1; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p1 FOR VALUES WITH (modulus 16, remainder 1);


--
-- Name: search_index_p10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p10 FOR VALUES WITH (modulus 16, remainder 10);


--
-- Name: search_index_p11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p11 FOR VALUES WITH (modulus 16, remainder 11);


--
-- Name: search_index_p12; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p12 FOR VALUES WITH (modulus 16, remainder 12);


--
-- Name: search_index_p13; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p13 FOR VALUES WITH (modulus 16, remainder 13);


--
-- Name: search_index_p14; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p14 FOR VALUES WITH (modulus 16, remainder 14);


--
-- Name: search_index_p15; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p15 FOR VALUES WITH (modulus 16, remainder 15);


--
-- Name: search_index_p2; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p2 FOR VALUES WITH (modulus 16, remainder 2);


--
-- Name: search_index_p3; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p3 FOR VALUES WITH (modulus 16, remainder 3);


--
-- Name: search_index_p4; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p4 FOR VALUES WITH (modulus 16, remainder 4);


--
-- Name: search_index_p5; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p5 FOR VALUES WITH (modulus 16, remainder 5);


--
-- Name: search_index_p6; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p6 FOR VALUES WITH (modulus 16, remainder 6);


--
-- Name: search_index_p7; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p7 FOR VALUES WITH (modulus 16, remainder 7);


--
-- Name: search_index_p8; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p8 FOR VALUES WITH (modulus 16, remainder 8);


--
-- Name: search_index_p9; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ATTACH PARTITION public.search_index_p9 FOR VALUES WITH (modulus 16, remainder 9);


--
-- Name: user_item_status_p0; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p0 FOR VALUES WITH (modulus 16, remainder 0);


--
-- Name: user_item_status_p1; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p1 FOR VALUES WITH (modulus 16, remainder 1);


--
-- Name: user_item_status_p10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p10 FOR VALUES WITH (modulus 16, remainder 10);


--
-- Name: user_item_status_p11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p11 FOR VALUES WITH (modulus 16, remainder 11);


--
-- Name: user_item_status_p12; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p12 FOR VALUES WITH (modulus 16, remainder 12);


--
-- Name: user_item_status_p13; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p13 FOR VALUES WITH (modulus 16, remainder 13);


--
-- Name: user_item_status_p14; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p14 FOR VALUES WITH (modulus 16, remainder 14);


--
-- Name: user_item_status_p15; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p15 FOR VALUES WITH (modulus 16, remainder 15);


--
-- Name: user_item_status_p2; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p2 FOR VALUES WITH (modulus 16, remainder 2);


--
-- Name: user_item_status_p3; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p3 FOR VALUES WITH (modulus 16, remainder 3);


--
-- Name: user_item_status_p4; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p4 FOR VALUES WITH (modulus 16, remainder 4);


--
-- Name: user_item_status_p5; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p5 FOR VALUES WITH (modulus 16, remainder 5);


--
-- Name: user_item_status_p6; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p6 FOR VALUES WITH (modulus 16, remainder 6);


--
-- Name: user_item_status_p7; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p7 FOR VALUES WITH (modulus 16, remainder 7);


--
-- Name: user_item_status_p8; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p8 FOR VALUES WITH (modulus 16, remainder 8);


--
-- Name: user_item_status_p9; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status ATTACH PARTITION public.user_item_status_p9 FOR VALUES WITH (modulus 16, remainder 9);


--
-- Name: search_index sort_key; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index ALTER COLUMN sort_key SET DEFAULT nextval('public.search_index_sort_key_seq'::regclass);


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
-- Name: automation_rule_run_resources automation_rule_run_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_run_resources
    ADD CONSTRAINT automation_rule_run_resources_pkey PRIMARY KEY (id);


--
-- Name: automation_rule_runs automation_rule_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_runs
    ADD CONSTRAINT automation_rule_runs_pkey PRIMARY KEY (id);


--
-- Name: automation_rules automation_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT automation_rules_pkey PRIMARY KEY (id);


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
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


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
-- Name: notification_recipients notification_recipients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_recipients
    ADD CONSTRAINT notification_recipients_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


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
-- Name: representation_session_events representation_session_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_events
    ADD CONSTRAINT representation_session_events_pkey PRIMARY KEY (id);


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
-- Name: search_index search_index_partitioned_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index
    ADD CONSTRAINT search_index_partitioned_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p0 search_index_p0_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p0
    ADD CONSTRAINT search_index_p0_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p10 search_index_p10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p10
    ADD CONSTRAINT search_index_p10_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p11 search_index_p11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p11
    ADD CONSTRAINT search_index_p11_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p12 search_index_p12_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p12
    ADD CONSTRAINT search_index_p12_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p13 search_index_p13_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p13
    ADD CONSTRAINT search_index_p13_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p14 search_index_p14_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p14
    ADD CONSTRAINT search_index_p14_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p15 search_index_p15_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p15
    ADD CONSTRAINT search_index_p15_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p1 search_index_p1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p1
    ADD CONSTRAINT search_index_p1_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p2 search_index_p2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p2
    ADD CONSTRAINT search_index_p2_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p3 search_index_p3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p3
    ADD CONSTRAINT search_index_p3_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p4 search_index_p4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p4
    ADD CONSTRAINT search_index_p4_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p5 search_index_p5_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p5
    ADD CONSTRAINT search_index_p5_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p6 search_index_p6_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p6
    ADD CONSTRAINT search_index_p6_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p7 search_index_p7_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p7
    ADD CONSTRAINT search_index_p7_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p8 search_index_p8_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p8
    ADD CONSTRAINT search_index_p8_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: search_index_p9 search_index_p9_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_index_p9
    ADD CONSTRAINT search_index_p9_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: invites studio_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT studio_invites_pkey PRIMARY KEY (id);


--
-- Name: collective_members studio_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collective_members
    ADD CONSTRAINT studio_users_pkey PRIMARY KEY (id);


--
-- Name: collectives studios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collectives
    ADD CONSTRAINT studios_pkey PRIMARY KEY (id);


--
-- Name: ai_agent_task_run_resources subagent_task_run_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_run_resources
    ADD CONSTRAINT subagent_task_run_resources_pkey PRIMARY KEY (id);


--
-- Name: ai_agent_task_runs subagent_task_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_runs
    ADD CONSTRAINT subagent_task_runs_pkey PRIMARY KEY (id);


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
-- Name: trustee_grants trustee_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_grants
    ADD CONSTRAINT trustee_permissions_pkey PRIMARY KEY (id);


--
-- Name: user_item_status user_item_status_partitioned_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status
    ADD CONSTRAINT user_item_status_partitioned_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p0 user_item_status_p0_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p0
    ADD CONSTRAINT user_item_status_p0_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p10 user_item_status_p10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p10
    ADD CONSTRAINT user_item_status_p10_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p11 user_item_status_p11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p11
    ADD CONSTRAINT user_item_status_p11_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p12 user_item_status_p12_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p12
    ADD CONSTRAINT user_item_status_p12_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p13 user_item_status_p13_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p13
    ADD CONSTRAINT user_item_status_p13_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p14 user_item_status_p14_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p14
    ADD CONSTRAINT user_item_status_p14_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p15 user_item_status_p15_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p15
    ADD CONSTRAINT user_item_status_p15_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p1 user_item_status_p1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p1
    ADD CONSTRAINT user_item_status_p1_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p2 user_item_status_p2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p2
    ADD CONSTRAINT user_item_status_p2_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p3 user_item_status_p3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p3
    ADD CONSTRAINT user_item_status_p3_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p4 user_item_status_p4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p4
    ADD CONSTRAINT user_item_status_p4_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p5 user_item_status_p5_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p5
    ADD CONSTRAINT user_item_status_p5_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p6 user_item_status_p6_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p6
    ADD CONSTRAINT user_item_status_p6_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p7 user_item_status_p7_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p7
    ADD CONSTRAINT user_item_status_p7_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p8 user_item_status_p8_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p8
    ADD CONSTRAINT user_item_status_p8_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: user_item_status_p9 user_item_status_p9_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_item_status_p9
    ADD CONSTRAINT user_item_status_p9_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: webhook_deliveries webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: idx_members_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_members_collective_id ON public.collective_members USING btree (collective_id);


--
-- Name: idx_members_tenant_collective_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_members_tenant_collective_user ON public.collective_members USING btree (tenant_id, collective_id, user_id);


--
-- Name: idx_rep_events_context; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_context ON public.representation_session_events USING btree (tenant_id, context_resource_type, context_resource_id);


--
-- Name: idx_rep_events_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_request ON public.representation_session_events USING btree (tenant_id, request_id);


--
-- Name: idx_rep_events_resource_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_resource_action ON public.representation_session_events USING btree (tenant_id, resource_type, resource_id, action_name);


--
-- Name: idx_rep_events_resource_collective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_resource_collective ON public.representation_session_events USING btree (resource_collective_id);


--
-- Name: idx_rep_events_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_session_id ON public.representation_session_events USING btree (representation_session_id);


--
-- Name: idx_rep_events_session_timeline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rep_events_session_timeline ON public.representation_session_events USING btree (tenant_id, representation_session_id, created_at);


--
-- Name: idx_search_index_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_created ON ONLY public.search_index USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: idx_search_index_cursor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_cursor ON ONLY public.search_index USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: idx_search_index_deadline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_deadline ON ONLY public.search_index USING btree (tenant_id, collective_id, deadline);


--
-- Name: idx_search_index_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_item ON ONLY public.search_index USING btree (item_type, item_id);


--
-- Name: idx_search_index_replying_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_replying_to ON ONLY public.search_index USING btree (tenant_id, replying_to_id);


--
-- Name: idx_search_index_subtype; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_subtype ON ONLY public.search_index USING btree (tenant_id, collective_id, subtype);


--
-- Name: idx_search_index_tenant_collective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_tenant_collective ON ONLY public.search_index USING btree (tenant_id, collective_id);


--
-- Name: idx_search_index_trigram; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_trigram ON ONLY public.search_index USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: idx_search_index_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_index_type ON ONLY public.search_index USING btree (tenant_id, collective_id, item_type);


--
-- Name: idx_search_index_unique_item; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_search_index_unique_item ON ONLY public.search_index USING btree (tenant_id, item_type, item_id);


--
-- Name: idx_task_run_resources_on_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_run_resources_on_resource ON public.ai_agent_task_run_resources USING btree (resource_type, resource_id);


--
-- Name: idx_task_run_resources_on_resource_collective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_run_resources_on_resource_collective ON public.ai_agent_task_run_resources USING btree (resource_collective_id);


--
-- Name: idx_task_run_resources_on_task_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_run_resources_on_task_run_id ON public.ai_agent_task_run_resources USING btree (ai_agent_task_run_id);


--
-- Name: idx_task_run_resources_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_task_run_resources_unique ON public.ai_agent_task_run_resources USING btree (ai_agent_task_run_id, resource_id, resource_type);


--
-- Name: idx_user_item_status_not_participating; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_item_status_not_participating ON ONLY public.user_item_status USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: idx_user_item_status_not_voted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_item_status_not_voted ON ONLY public.user_item_status USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: idx_user_item_status_tenant_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_item_status_tenant_user ON ONLY public.user_item_status USING btree (tenant_id, user_id);


--
-- Name: idx_user_item_status_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_user_item_status_unique ON ONLY public.user_item_status USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: idx_user_item_status_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_item_status_unread ON ONLY public.user_item_status USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


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
-- Name: index_ai_agent_task_run_resources_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_run_resources_on_tenant_id ON public.ai_agent_task_run_resources USING btree (tenant_id);


--
-- Name: index_ai_agent_task_runs_on_ai_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_ai_agent_id ON public.ai_agent_task_runs USING btree (ai_agent_id);


--
-- Name: index_ai_agent_task_runs_on_ai_agent_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_ai_agent_id_and_created_at ON public.ai_agent_task_runs USING btree (ai_agent_id, created_at);


--
-- Name: index_ai_agent_task_runs_on_automation_rule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_automation_rule_id ON public.ai_agent_task_runs USING btree (automation_rule_id);


--
-- Name: index_ai_agent_task_runs_on_initiated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_initiated_by_id ON public.ai_agent_task_runs USING btree (initiated_by_id);


--
-- Name: index_ai_agent_task_runs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_status ON public.ai_agent_task_runs USING btree (status);


--
-- Name: index_ai_agent_task_runs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_tenant_id ON public.ai_agent_task_runs USING btree (tenant_id);


--
-- Name: index_ai_agent_task_runs_on_tenant_id_and_ai_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_tenant_id_and_ai_agent_id ON public.ai_agent_task_runs USING btree (tenant_id, ai_agent_id);


--
-- Name: index_ai_agent_task_runs_on_tenant_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_tenant_id_and_created_at ON public.ai_agent_task_runs USING btree (tenant_id, created_at);


--
-- Name: index_ai_agent_task_runs_on_tenant_id_and_initiated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_task_runs_on_tenant_id_and_initiated_by_id ON public.ai_agent_task_runs USING btree (tenant_id, initiated_by_id);


--
-- Name: index_api_tokens_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_tenant_id ON public.api_tokens USING btree (tenant_id);


--
-- Name: index_api_tokens_on_tenant_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_tenant_id_and_user_id ON public.api_tokens USING btree (tenant_id, user_id);


--
-- Name: index_api_tokens_on_token_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_tokens_on_token_hash ON public.api_tokens USING btree (token_hash);


--
-- Name: index_api_tokens_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_tokens_on_user_id ON public.api_tokens USING btree (user_id);


--
-- Name: index_attachments_on_attachable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_attachable ON public.attachments USING btree (attachable_type, attachable_id);


--
-- Name: index_attachments_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_collective_id ON public.attachments USING btree (collective_id);


--
-- Name: index_attachments_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_created_by_id ON public.attachments USING btree (created_by_id);


--
-- Name: index_attachments_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_tenant_id ON public.attachments USING btree (tenant_id);


--
-- Name: index_attachments_on_tenant_studio_attachable_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_attachments_on_tenant_studio_attachable_name ON public.attachments USING btree (tenant_id, collective_id, attachable_id, name);


--
-- Name: index_attachments_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_updated_by_id ON public.attachments USING btree (updated_by_id);


--
-- Name: index_automation_rule_run_resources_on_automation_rule_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_run_resources_on_automation_rule_run_id ON public.automation_rule_run_resources USING btree (automation_rule_run_id);


--
-- Name: index_automation_rule_run_resources_on_resource_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_run_resources_on_resource_collective_id ON public.automation_rule_run_resources USING btree (resource_collective_id);


--
-- Name: index_automation_rule_run_resources_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_run_resources_on_tenant_id ON public.automation_rule_run_resources USING btree (tenant_id);


--
-- Name: index_automation_rule_runs_on_ai_agent_task_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_ai_agent_task_run_id ON public.automation_rule_runs USING btree (ai_agent_task_run_id);


--
-- Name: index_automation_rule_runs_on_automation_rule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_automation_rule_id ON public.automation_rule_runs USING btree (automation_rule_id);


--
-- Name: index_automation_rule_runs_on_collective_and_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_collective_and_created ON public.automation_rule_runs USING btree (collective_id, created_at);


--
-- Name: index_automation_rule_runs_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_collective_id ON public.automation_rule_runs USING btree (collective_id);


--
-- Name: index_automation_rule_runs_on_rule_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_rule_and_status ON public.automation_rule_runs USING btree (automation_rule_id, status);


--
-- Name: index_automation_rule_runs_on_tenant_and_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_tenant_and_created ON public.automation_rule_runs USING btree (tenant_id, created_at);


--
-- Name: index_automation_rule_runs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_tenant_id ON public.automation_rule_runs USING btree (tenant_id);


--
-- Name: index_automation_rule_runs_on_triggered_by_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rule_runs_on_triggered_by_event_id ON public.automation_rule_runs USING btree (triggered_by_event_id);


--
-- Name: index_automation_rules_on_ai_agent_and_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_ai_agent_and_enabled ON public.automation_rules USING btree (ai_agent_id, enabled);


--
-- Name: index_automation_rules_on_ai_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_ai_agent_id ON public.automation_rules USING btree (ai_agent_id);


--
-- Name: index_automation_rules_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_collective_id ON public.automation_rules USING btree (collective_id);


--
-- Name: index_automation_rules_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_created_by_id ON public.automation_rules USING btree (created_by_id);


--
-- Name: index_automation_rules_on_tenant_collective_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_tenant_collective_enabled ON public.automation_rules USING btree (tenant_id, collective_id, enabled);


--
-- Name: index_automation_rules_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_tenant_id ON public.automation_rules USING btree (tenant_id);


--
-- Name: index_automation_rules_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_automation_rules_on_truncated_id ON public.automation_rules USING btree (truncated_id);


--
-- Name: index_automation_rules_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_updated_by_id ON public.automation_rules USING btree (updated_by_id);


--
-- Name: index_automation_rules_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_user_id ON public.automation_rules USING btree (user_id);


--
-- Name: index_automation_rules_on_webhook_path; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_automation_rules_on_webhook_path ON public.automation_rules USING btree (webhook_path) WHERE (webhook_path IS NOT NULL);


--
-- Name: index_automation_run_resources_on_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_run_resources_on_resource ON public.automation_rule_run_resources USING btree (resource_type, resource_id);


--
-- Name: index_automation_run_resources_on_tenant_and_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_run_resources_on_tenant_and_resource ON public.automation_rule_run_resources USING btree (tenant_id, resource_type, resource_id);


--
-- Name: index_collective_members_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_collective_members_on_tenant_id ON public.collective_members USING btree (tenant_id);


--
-- Name: index_collective_members_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_collective_members_on_user_id ON public.collective_members USING btree (user_id);


--
-- Name: index_collectives_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_collectives_on_created_by_id ON public.collectives USING btree (created_by_id);


--
-- Name: index_collectives_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_collectives_on_tenant_id ON public.collectives USING btree (tenant_id);


--
-- Name: index_collectives_on_tenant_id_and_handle; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_collectives_on_tenant_id_and_handle ON public.collectives USING btree (tenant_id, handle);


--
-- Name: index_collectives_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_collectives_on_updated_by_id ON public.collectives USING btree (updated_by_id);


--
-- Name: index_commitment_participants_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_collective_id ON public.commitment_participants USING btree (collective_id);


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
-- Name: index_commitment_participants_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_tenant_id ON public.commitment_participants USING btree (tenant_id);


--
-- Name: index_commitment_participants_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitment_participants_on_user_id ON public.commitment_participants USING btree (user_id);


--
-- Name: index_commitments_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitments_on_collective_id ON public.commitments USING btree (collective_id);


--
-- Name: index_commitments_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commitments_on_created_by_id ON public.commitments USING btree (created_by_id);


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
-- Name: index_decision_participants_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_participants_on_collective_id ON public.decision_participants USING btree (collective_id);


--
-- Name: index_decision_participants_on_decision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_participants_on_decision_id ON public.decision_participants USING btree (decision_id);


--
-- Name: index_decision_participants_on_decision_id_and_participant_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_decision_participants_on_decision_id_and_participant_uid ON public.decision_participants USING btree (decision_id, participant_uid);


--
-- Name: index_decision_participants_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_participants_on_tenant_id ON public.decision_participants USING btree (tenant_id);


--
-- Name: index_decisions_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decisions_on_collective_id ON public.decisions USING btree (collective_id);


--
-- Name: index_decisions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decisions_on_created_by_id ON public.decisions USING btree (created_by_id);


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
-- Name: index_events_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_actor_id ON public.events USING btree (actor_id);


--
-- Name: index_events_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_collective_id ON public.events USING btree (collective_id);


--
-- Name: index_events_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_created_at ON public.events USING btree (created_at);


--
-- Name: index_events_on_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_event_type ON public.events USING btree (event_type);


--
-- Name: index_events_on_subject_type_and_subject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_subject_type_and_subject_id ON public.events USING btree (subject_type, subject_id);


--
-- Name: index_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_tenant_id ON public.events USING btree (tenant_id);


--
-- Name: index_heartbeats_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_heartbeats_on_collective_id ON public.heartbeats USING btree (collective_id);


--
-- Name: index_heartbeats_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_heartbeats_on_tenant_id ON public.heartbeats USING btree (tenant_id);


--
-- Name: index_heartbeats_on_tenant_studio_user_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_heartbeats_on_tenant_studio_user_expires_at ON public.heartbeats USING btree (tenant_id, collective_id, user_id, expires_at);


--
-- Name: index_heartbeats_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_heartbeats_on_truncated_id ON public.heartbeats USING btree (truncated_id);


--
-- Name: index_heartbeats_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_heartbeats_on_user_id ON public.heartbeats USING btree (user_id);


--
-- Name: index_invites_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_invites_on_code ON public.invites USING btree (code);


--
-- Name: index_invites_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_collective_id ON public.invites USING btree (collective_id);


--
-- Name: index_invites_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_created_by_id ON public.invites USING btree (created_by_id);


--
-- Name: index_invites_on_invited_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_invited_user_id ON public.invites USING btree (invited_user_id);


--
-- Name: index_invites_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_tenant_id ON public.invites USING btree (tenant_id);


--
-- Name: index_links_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_collective_id ON public.links USING btree (collective_id);


--
-- Name: index_links_on_from_linkable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_from_linkable ON public.links USING btree (from_linkable_type, from_linkable_id);


--
-- Name: index_links_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_tenant_id ON public.links USING btree (tenant_id);


--
-- Name: index_links_on_to_linkable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_links_on_to_linkable ON public.links USING btree (to_linkable_type, to_linkable_id);


--
-- Name: index_note_history_events_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_collective_id ON public.note_history_events USING btree (collective_id);


--
-- Name: index_note_history_events_on_note_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_note_id ON public.note_history_events USING btree (note_id);


--
-- Name: index_note_history_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_tenant_id ON public.note_history_events USING btree (tenant_id);


--
-- Name: index_note_history_events_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_note_history_events_on_user_id ON public.note_history_events USING btree (user_id);


--
-- Name: index_notes_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_collective_id ON public.notes USING btree (collective_id);


--
-- Name: index_notes_on_commentable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_commentable ON public.notes USING btree (commentable_type, commentable_id);


--
-- Name: index_notes_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_created_by_id ON public.notes USING btree (created_by_id);


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
-- Name: index_notification_recipients_on_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_recipients_on_channel ON public.notification_recipients USING btree (channel);


--
-- Name: index_notification_recipients_on_notification_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_recipients_on_notification_id ON public.notification_recipients USING btree (notification_id);


--
-- Name: index_notification_recipients_on_scheduled_for; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_recipients_on_scheduled_for ON public.notification_recipients USING btree (scheduled_for) WHERE (scheduled_for IS NOT NULL);


--
-- Name: index_notification_recipients_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_recipients_on_status ON public.notification_recipients USING btree (status);


--
-- Name: index_notification_recipients_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_recipients_on_tenant_id ON public.notification_recipients USING btree (tenant_id);


--
-- Name: index_notification_recipients_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_recipients_on_user_id ON public.notification_recipients USING btree (user_id);


--
-- Name: index_notification_recipients_on_user_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_recipients_on_user_id_and_status ON public.notification_recipients USING btree (user_id, status);


--
-- Name: index_notifications_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_created_at ON public.notifications USING btree (created_at);


--
-- Name: index_notifications_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_event_id ON public.notifications USING btree (event_id);


--
-- Name: index_notifications_on_notification_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_notification_type ON public.notifications USING btree (notification_type);


--
-- Name: index_notifications_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_tenant_id ON public.notifications USING btree (tenant_id);


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
-- Name: index_options_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_options_on_collective_id ON public.options USING btree (collective_id);


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
-- Name: index_options_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_options_on_tenant_id ON public.options USING btree (tenant_id);


--
-- Name: index_representation_session_events_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_session_events_on_collective_id ON public.representation_session_events USING btree (collective_id);


--
-- Name: index_representation_session_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_session_events_on_tenant_id ON public.representation_session_events USING btree (tenant_id);


--
-- Name: index_representation_sessions_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_collective_id ON public.representation_sessions USING btree (collective_id);


--
-- Name: index_representation_sessions_on_representative_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_representative_user_id ON public.representation_sessions USING btree (representative_user_id);


--
-- Name: index_representation_sessions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_tenant_id ON public.representation_sessions USING btree (tenant_id);


--
-- Name: index_representation_sessions_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_representation_sessions_on_truncated_id ON public.representation_sessions USING btree (truncated_id);


--
-- Name: index_representation_sessions_on_trustee_grant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_representation_sessions_on_trustee_grant_id ON public.representation_sessions USING btree (trustee_grant_id);


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
-- Name: index_tenants_on_main_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tenants_on_main_collective_id ON public.tenants USING btree (main_collective_id);


--
-- Name: index_tenants_on_subdomain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_subdomain ON public.tenants USING btree (subdomain);


--
-- Name: index_trustee_grants_on_accepted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trustee_grants_on_accepted_at ON public.trustee_grants USING btree (accepted_at);


--
-- Name: index_trustee_grants_on_granting_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trustee_grants_on_granting_user_id ON public.trustee_grants USING btree (granting_user_id);


--
-- Name: index_trustee_grants_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trustee_grants_on_tenant_id ON public.trustee_grants USING btree (tenant_id);


--
-- Name: index_trustee_grants_on_truncated_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_trustee_grants_on_truncated_id ON public.trustee_grants USING btree (truncated_id);


--
-- Name: index_trustee_grants_on_trustee_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trustee_grants_on_trustee_user_id ON public.trustee_grants USING btree (trustee_user_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_parent_id ON public.users USING btree (parent_id);


--
-- Name: index_users_on_suspended_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_suspended_at ON public.users USING btree (suspended_at);


--
-- Name: index_votes_on_collective_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_votes_on_collective_id ON public.votes USING btree (collective_id);


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
-- Name: index_votes_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_votes_on_tenant_id ON public.votes USING btree (tenant_id);


--
-- Name: index_webhook_deliveries_on_automation_rule_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_webhook_deliveries_on_automation_rule_run_id ON public.webhook_deliveries USING btree (automation_rule_run_id);


--
-- Name: index_webhook_deliveries_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_webhook_deliveries_on_event_id ON public.webhook_deliveries USING btree (event_id);


--
-- Name: index_webhook_deliveries_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_webhook_deliveries_on_status ON public.webhook_deliveries USING btree (status);


--
-- Name: index_webhook_deliveries_on_status_and_next_retry_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_webhook_deliveries_on_status_and_next_retry_at ON public.webhook_deliveries USING btree (status, next_retry_at);


--
-- Name: index_webhook_deliveries_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_webhook_deliveries_on_tenant_id ON public.webhook_deliveries USING btree (tenant_id);


--
-- Name: search_index_p0_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_item_type_item_id_idx ON public.search_index_p0 USING btree (item_type, item_id);


--
-- Name: search_index_p0_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_searchable_text_idx ON public.search_index_p0 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p0_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_tenant_id_collective_id_created_at_idx ON public.search_index_p0 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p0_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_tenant_id_collective_id_deadline_idx ON public.search_index_p0 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p0_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_tenant_id_collective_id_idx ON public.search_index_p0 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p0_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_tenant_id_collective_id_item_type_idx ON public.search_index_p0 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p0_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_tenant_id_collective_id_sort_key_idx ON public.search_index_p0 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p0_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_tenant_id_collective_id_subtype_idx ON public.search_index_p0 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p0_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p0_tenant_id_item_type_item_id_idx ON public.search_index_p0 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p0_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p0_tenant_id_replying_to_id_idx ON public.search_index_p0 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p10_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_item_type_item_id_idx ON public.search_index_p10 USING btree (item_type, item_id);


--
-- Name: search_index_p10_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_searchable_text_idx ON public.search_index_p10 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p10_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_tenant_id_collective_id_created_at_idx ON public.search_index_p10 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p10_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_tenant_id_collective_id_deadline_idx ON public.search_index_p10 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p10_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_tenant_id_collective_id_idx ON public.search_index_p10 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p10_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_tenant_id_collective_id_item_type_idx ON public.search_index_p10 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p10_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_tenant_id_collective_id_sort_key_idx ON public.search_index_p10 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p10_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_tenant_id_collective_id_subtype_idx ON public.search_index_p10 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p10_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p10_tenant_id_item_type_item_id_idx ON public.search_index_p10 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p10_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p10_tenant_id_replying_to_id_idx ON public.search_index_p10 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p11_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_item_type_item_id_idx ON public.search_index_p11 USING btree (item_type, item_id);


--
-- Name: search_index_p11_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_searchable_text_idx ON public.search_index_p11 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p11_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_tenant_id_collective_id_created_at_idx ON public.search_index_p11 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p11_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_tenant_id_collective_id_deadline_idx ON public.search_index_p11 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p11_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_tenant_id_collective_id_idx ON public.search_index_p11 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p11_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_tenant_id_collective_id_item_type_idx ON public.search_index_p11 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p11_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_tenant_id_collective_id_sort_key_idx ON public.search_index_p11 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p11_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_tenant_id_collective_id_subtype_idx ON public.search_index_p11 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p11_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p11_tenant_id_item_type_item_id_idx ON public.search_index_p11 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p11_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p11_tenant_id_replying_to_id_idx ON public.search_index_p11 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p12_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_item_type_item_id_idx ON public.search_index_p12 USING btree (item_type, item_id);


--
-- Name: search_index_p12_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_searchable_text_idx ON public.search_index_p12 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p12_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_tenant_id_collective_id_created_at_idx ON public.search_index_p12 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p12_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_tenant_id_collective_id_deadline_idx ON public.search_index_p12 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p12_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_tenant_id_collective_id_idx ON public.search_index_p12 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p12_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_tenant_id_collective_id_item_type_idx ON public.search_index_p12 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p12_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_tenant_id_collective_id_sort_key_idx ON public.search_index_p12 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p12_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_tenant_id_collective_id_subtype_idx ON public.search_index_p12 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p12_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p12_tenant_id_item_type_item_id_idx ON public.search_index_p12 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p12_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p12_tenant_id_replying_to_id_idx ON public.search_index_p12 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p13_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_item_type_item_id_idx ON public.search_index_p13 USING btree (item_type, item_id);


--
-- Name: search_index_p13_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_searchable_text_idx ON public.search_index_p13 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p13_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_tenant_id_collective_id_created_at_idx ON public.search_index_p13 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p13_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_tenant_id_collective_id_deadline_idx ON public.search_index_p13 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p13_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_tenant_id_collective_id_idx ON public.search_index_p13 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p13_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_tenant_id_collective_id_item_type_idx ON public.search_index_p13 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p13_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_tenant_id_collective_id_sort_key_idx ON public.search_index_p13 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p13_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_tenant_id_collective_id_subtype_idx ON public.search_index_p13 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p13_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p13_tenant_id_item_type_item_id_idx ON public.search_index_p13 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p13_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p13_tenant_id_replying_to_id_idx ON public.search_index_p13 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p14_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_item_type_item_id_idx ON public.search_index_p14 USING btree (item_type, item_id);


--
-- Name: search_index_p14_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_searchable_text_idx ON public.search_index_p14 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p14_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_tenant_id_collective_id_created_at_idx ON public.search_index_p14 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p14_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_tenant_id_collective_id_deadline_idx ON public.search_index_p14 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p14_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_tenant_id_collective_id_idx ON public.search_index_p14 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p14_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_tenant_id_collective_id_item_type_idx ON public.search_index_p14 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p14_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_tenant_id_collective_id_sort_key_idx ON public.search_index_p14 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p14_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_tenant_id_collective_id_subtype_idx ON public.search_index_p14 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p14_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p14_tenant_id_item_type_item_id_idx ON public.search_index_p14 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p14_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p14_tenant_id_replying_to_id_idx ON public.search_index_p14 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p15_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_item_type_item_id_idx ON public.search_index_p15 USING btree (item_type, item_id);


--
-- Name: search_index_p15_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_searchable_text_idx ON public.search_index_p15 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p15_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_tenant_id_collective_id_created_at_idx ON public.search_index_p15 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p15_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_tenant_id_collective_id_deadline_idx ON public.search_index_p15 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p15_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_tenant_id_collective_id_idx ON public.search_index_p15 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p15_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_tenant_id_collective_id_item_type_idx ON public.search_index_p15 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p15_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_tenant_id_collective_id_sort_key_idx ON public.search_index_p15 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p15_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_tenant_id_collective_id_subtype_idx ON public.search_index_p15 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p15_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p15_tenant_id_item_type_item_id_idx ON public.search_index_p15 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p15_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p15_tenant_id_replying_to_id_idx ON public.search_index_p15 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p1_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_item_type_item_id_idx ON public.search_index_p1 USING btree (item_type, item_id);


--
-- Name: search_index_p1_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_searchable_text_idx ON public.search_index_p1 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p1_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_tenant_id_collective_id_created_at_idx ON public.search_index_p1 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p1_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_tenant_id_collective_id_deadline_idx ON public.search_index_p1 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p1_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_tenant_id_collective_id_idx ON public.search_index_p1 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p1_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_tenant_id_collective_id_item_type_idx ON public.search_index_p1 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p1_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_tenant_id_collective_id_sort_key_idx ON public.search_index_p1 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p1_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_tenant_id_collective_id_subtype_idx ON public.search_index_p1 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p1_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p1_tenant_id_item_type_item_id_idx ON public.search_index_p1 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p1_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p1_tenant_id_replying_to_id_idx ON public.search_index_p1 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p2_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_item_type_item_id_idx ON public.search_index_p2 USING btree (item_type, item_id);


--
-- Name: search_index_p2_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_searchable_text_idx ON public.search_index_p2 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p2_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_tenant_id_collective_id_created_at_idx ON public.search_index_p2 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p2_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_tenant_id_collective_id_deadline_idx ON public.search_index_p2 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p2_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_tenant_id_collective_id_idx ON public.search_index_p2 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p2_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_tenant_id_collective_id_item_type_idx ON public.search_index_p2 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p2_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_tenant_id_collective_id_sort_key_idx ON public.search_index_p2 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p2_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_tenant_id_collective_id_subtype_idx ON public.search_index_p2 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p2_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p2_tenant_id_item_type_item_id_idx ON public.search_index_p2 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p2_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p2_tenant_id_replying_to_id_idx ON public.search_index_p2 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p3_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_item_type_item_id_idx ON public.search_index_p3 USING btree (item_type, item_id);


--
-- Name: search_index_p3_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_searchable_text_idx ON public.search_index_p3 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p3_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_tenant_id_collective_id_created_at_idx ON public.search_index_p3 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p3_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_tenant_id_collective_id_deadline_idx ON public.search_index_p3 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p3_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_tenant_id_collective_id_idx ON public.search_index_p3 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p3_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_tenant_id_collective_id_item_type_idx ON public.search_index_p3 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p3_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_tenant_id_collective_id_sort_key_idx ON public.search_index_p3 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p3_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_tenant_id_collective_id_subtype_idx ON public.search_index_p3 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p3_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p3_tenant_id_item_type_item_id_idx ON public.search_index_p3 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p3_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p3_tenant_id_replying_to_id_idx ON public.search_index_p3 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p4_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_item_type_item_id_idx ON public.search_index_p4 USING btree (item_type, item_id);


--
-- Name: search_index_p4_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_searchable_text_idx ON public.search_index_p4 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p4_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_tenant_id_collective_id_created_at_idx ON public.search_index_p4 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p4_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_tenant_id_collective_id_deadline_idx ON public.search_index_p4 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p4_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_tenant_id_collective_id_idx ON public.search_index_p4 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p4_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_tenant_id_collective_id_item_type_idx ON public.search_index_p4 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p4_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_tenant_id_collective_id_sort_key_idx ON public.search_index_p4 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p4_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_tenant_id_collective_id_subtype_idx ON public.search_index_p4 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p4_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p4_tenant_id_item_type_item_id_idx ON public.search_index_p4 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p4_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p4_tenant_id_replying_to_id_idx ON public.search_index_p4 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p5_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_item_type_item_id_idx ON public.search_index_p5 USING btree (item_type, item_id);


--
-- Name: search_index_p5_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_searchable_text_idx ON public.search_index_p5 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p5_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_tenant_id_collective_id_created_at_idx ON public.search_index_p5 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p5_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_tenant_id_collective_id_deadline_idx ON public.search_index_p5 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p5_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_tenant_id_collective_id_idx ON public.search_index_p5 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p5_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_tenant_id_collective_id_item_type_idx ON public.search_index_p5 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p5_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_tenant_id_collective_id_sort_key_idx ON public.search_index_p5 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p5_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_tenant_id_collective_id_subtype_idx ON public.search_index_p5 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p5_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p5_tenant_id_item_type_item_id_idx ON public.search_index_p5 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p5_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p5_tenant_id_replying_to_id_idx ON public.search_index_p5 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p6_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_item_type_item_id_idx ON public.search_index_p6 USING btree (item_type, item_id);


--
-- Name: search_index_p6_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_searchable_text_idx ON public.search_index_p6 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p6_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_tenant_id_collective_id_created_at_idx ON public.search_index_p6 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p6_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_tenant_id_collective_id_deadline_idx ON public.search_index_p6 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p6_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_tenant_id_collective_id_idx ON public.search_index_p6 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p6_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_tenant_id_collective_id_item_type_idx ON public.search_index_p6 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p6_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_tenant_id_collective_id_sort_key_idx ON public.search_index_p6 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p6_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_tenant_id_collective_id_subtype_idx ON public.search_index_p6 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p6_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p6_tenant_id_item_type_item_id_idx ON public.search_index_p6 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p6_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p6_tenant_id_replying_to_id_idx ON public.search_index_p6 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p7_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_item_type_item_id_idx ON public.search_index_p7 USING btree (item_type, item_id);


--
-- Name: search_index_p7_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_searchable_text_idx ON public.search_index_p7 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p7_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_tenant_id_collective_id_created_at_idx ON public.search_index_p7 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p7_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_tenant_id_collective_id_deadline_idx ON public.search_index_p7 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p7_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_tenant_id_collective_id_idx ON public.search_index_p7 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p7_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_tenant_id_collective_id_item_type_idx ON public.search_index_p7 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p7_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_tenant_id_collective_id_sort_key_idx ON public.search_index_p7 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p7_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_tenant_id_collective_id_subtype_idx ON public.search_index_p7 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p7_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p7_tenant_id_item_type_item_id_idx ON public.search_index_p7 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p7_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p7_tenant_id_replying_to_id_idx ON public.search_index_p7 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p8_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_item_type_item_id_idx ON public.search_index_p8 USING btree (item_type, item_id);


--
-- Name: search_index_p8_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_searchable_text_idx ON public.search_index_p8 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p8_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_tenant_id_collective_id_created_at_idx ON public.search_index_p8 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p8_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_tenant_id_collective_id_deadline_idx ON public.search_index_p8 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p8_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_tenant_id_collective_id_idx ON public.search_index_p8 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p8_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_tenant_id_collective_id_item_type_idx ON public.search_index_p8 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p8_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_tenant_id_collective_id_sort_key_idx ON public.search_index_p8 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p8_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_tenant_id_collective_id_subtype_idx ON public.search_index_p8 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p8_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p8_tenant_id_item_type_item_id_idx ON public.search_index_p8 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p8_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p8_tenant_id_replying_to_id_idx ON public.search_index_p8 USING btree (tenant_id, replying_to_id);


--
-- Name: search_index_p9_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_item_type_item_id_idx ON public.search_index_p9 USING btree (item_type, item_id);


--
-- Name: search_index_p9_searchable_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_searchable_text_idx ON public.search_index_p9 USING gin (searchable_text public.gin_trgm_ops);


--
-- Name: search_index_p9_tenant_id_collective_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_tenant_id_collective_id_created_at_idx ON public.search_index_p9 USING btree (tenant_id, collective_id, created_at DESC);


--
-- Name: search_index_p9_tenant_id_collective_id_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_tenant_id_collective_id_deadline_idx ON public.search_index_p9 USING btree (tenant_id, collective_id, deadline);


--
-- Name: search_index_p9_tenant_id_collective_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_tenant_id_collective_id_idx ON public.search_index_p9 USING btree (tenant_id, collective_id);


--
-- Name: search_index_p9_tenant_id_collective_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_tenant_id_collective_id_item_type_idx ON public.search_index_p9 USING btree (tenant_id, collective_id, item_type);


--
-- Name: search_index_p9_tenant_id_collective_id_sort_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_tenant_id_collective_id_sort_key_idx ON public.search_index_p9 USING btree (tenant_id, collective_id, sort_key DESC);


--
-- Name: search_index_p9_tenant_id_collective_id_subtype_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_tenant_id_collective_id_subtype_idx ON public.search_index_p9 USING btree (tenant_id, collective_id, subtype);


--
-- Name: search_index_p9_tenant_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX search_index_p9_tenant_id_item_type_item_id_idx ON public.search_index_p9 USING btree (tenant_id, item_type, item_id);


--
-- Name: search_index_p9_tenant_id_replying_to_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX search_index_p9_tenant_id_replying_to_id_idx ON public.search_index_p9 USING btree (tenant_id, replying_to_id);


--
-- Name: user_item_status_p0_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p0_tenant_id_user_id_idx ON public.user_item_status_p0 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p0_tenant_id_user_id_item_type_idx ON public.user_item_status_p0 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p0_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p0 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p0_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p0 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p0_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p0 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p10_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p10_tenant_id_user_id_idx ON public.user_item_status_p10 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p10_tenant_id_user_id_item_type_idx ON public.user_item_status_p10 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p10_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p10 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p10_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p10 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p10_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p10 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p11_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p11_tenant_id_user_id_idx ON public.user_item_status_p11 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p11_tenant_id_user_id_item_type_idx ON public.user_item_status_p11 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p11_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p11 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p11_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p11 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p11_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p11 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p12_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p12_tenant_id_user_id_idx ON public.user_item_status_p12 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p12_tenant_id_user_id_item_type_idx ON public.user_item_status_p12 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p12_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p12 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p12_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p12 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p12_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p12 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p13_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p13_tenant_id_user_id_idx ON public.user_item_status_p13 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p13_tenant_id_user_id_item_type_idx ON public.user_item_status_p13 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p13_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p13 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p13_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p13 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p13_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p13 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p14_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p14_tenant_id_user_id_idx ON public.user_item_status_p14 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p14_tenant_id_user_id_item_type_idx ON public.user_item_status_p14 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p14_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p14 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p14_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p14 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p14_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p14 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p15_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p15_tenant_id_user_id_idx ON public.user_item_status_p15 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p15_tenant_id_user_id_item_type_idx ON public.user_item_status_p15 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p15_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p15 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p15_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p15 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p15_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p15 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p1_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p1_tenant_id_user_id_idx ON public.user_item_status_p1 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p1_tenant_id_user_id_item_type_idx ON public.user_item_status_p1 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p1_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p1 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p1_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p1 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p1_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p1 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p2_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p2_tenant_id_user_id_idx ON public.user_item_status_p2 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p2_tenant_id_user_id_item_type_idx ON public.user_item_status_p2 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p2_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p2 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p2_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p2 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p2_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p2 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p3_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p3_tenant_id_user_id_idx ON public.user_item_status_p3 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p3_tenant_id_user_id_item_type_idx ON public.user_item_status_p3 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p3_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p3 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p3_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p3 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p3_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p3 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p4_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p4_tenant_id_user_id_idx ON public.user_item_status_p4 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p4_tenant_id_user_id_item_type_idx ON public.user_item_status_p4 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p4_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p4 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p4_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p4 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p4_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p4 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p5_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p5_tenant_id_user_id_idx ON public.user_item_status_p5 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p5_tenant_id_user_id_item_type_idx ON public.user_item_status_p5 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p5_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p5 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p5_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p5 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p5_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p5 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p6_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p6_tenant_id_user_id_idx ON public.user_item_status_p6 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p6_tenant_id_user_id_item_type_idx ON public.user_item_status_p6 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p6_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p6 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p6_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p6 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p6_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p6 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p7_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p7_tenant_id_user_id_idx ON public.user_item_status_p7 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p7_tenant_id_user_id_item_type_idx ON public.user_item_status_p7 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p7_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p7 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p7_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p7 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p7_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p7 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p8_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p8_tenant_id_user_id_idx ON public.user_item_status_p8 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p8_tenant_id_user_id_item_type_idx ON public.user_item_status_p8 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p8_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p8 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p8_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p8 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p8_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p8 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: user_item_status_p9_tenant_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p9_tenant_id_user_id_idx ON public.user_item_status_p9 USING btree (tenant_id, user_id);


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p9_tenant_id_user_id_item_type_idx ON public.user_item_status_p9 USING btree (tenant_id, user_id, item_type) WHERE (has_read = false);


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p9_tenant_id_user_id_item_type_idx1 ON public.user_item_status_p9 USING btree (tenant_id, user_id, item_type) WHERE (has_voted = false);


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_idx2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_item_status_p9_tenant_id_user_id_item_type_idx2 ON public.user_item_status_p9 USING btree (tenant_id, user_id, item_type) WHERE (is_participating = false);


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_item_status_p9_tenant_id_user_id_item_type_item_id_idx ON public.user_item_status_p9 USING btree (tenant_id, user_id, item_type, item_id);


--
-- Name: search_index_p0_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p0_item_type_item_id_idx;


--
-- Name: search_index_p0_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p0_pkey;


--
-- Name: search_index_p0_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p0_searchable_text_idx;


--
-- Name: search_index_p0_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p0_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p0_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p0_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p0_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p0_tenant_id_collective_id_idx;


--
-- Name: search_index_p0_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p0_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p0_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p0_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p0_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p0_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p0_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p0_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p0_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p0_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p10_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p10_item_type_item_id_idx;


--
-- Name: search_index_p10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p10_pkey;


--
-- Name: search_index_p10_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p10_searchable_text_idx;


--
-- Name: search_index_p10_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p10_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p10_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p10_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p10_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p10_tenant_id_collective_id_idx;


--
-- Name: search_index_p10_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p10_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p10_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p10_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p10_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p10_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p10_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p10_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p10_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p10_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p11_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p11_item_type_item_id_idx;


--
-- Name: search_index_p11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p11_pkey;


--
-- Name: search_index_p11_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p11_searchable_text_idx;


--
-- Name: search_index_p11_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p11_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p11_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p11_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p11_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p11_tenant_id_collective_id_idx;


--
-- Name: search_index_p11_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p11_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p11_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p11_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p11_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p11_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p11_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p11_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p11_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p11_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p12_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p12_item_type_item_id_idx;


--
-- Name: search_index_p12_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p12_pkey;


--
-- Name: search_index_p12_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p12_searchable_text_idx;


--
-- Name: search_index_p12_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p12_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p12_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p12_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p12_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p12_tenant_id_collective_id_idx;


--
-- Name: search_index_p12_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p12_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p12_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p12_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p12_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p12_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p12_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p12_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p12_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p12_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p13_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p13_item_type_item_id_idx;


--
-- Name: search_index_p13_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p13_pkey;


--
-- Name: search_index_p13_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p13_searchable_text_idx;


--
-- Name: search_index_p13_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p13_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p13_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p13_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p13_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p13_tenant_id_collective_id_idx;


--
-- Name: search_index_p13_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p13_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p13_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p13_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p13_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p13_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p13_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p13_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p13_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p13_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p14_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p14_item_type_item_id_idx;


--
-- Name: search_index_p14_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p14_pkey;


--
-- Name: search_index_p14_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p14_searchable_text_idx;


--
-- Name: search_index_p14_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p14_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p14_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p14_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p14_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p14_tenant_id_collective_id_idx;


--
-- Name: search_index_p14_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p14_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p14_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p14_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p14_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p14_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p14_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p14_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p14_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p14_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p15_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p15_item_type_item_id_idx;


--
-- Name: search_index_p15_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p15_pkey;


--
-- Name: search_index_p15_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p15_searchable_text_idx;


--
-- Name: search_index_p15_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p15_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p15_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p15_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p15_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p15_tenant_id_collective_id_idx;


--
-- Name: search_index_p15_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p15_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p15_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p15_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p15_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p15_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p15_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p15_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p15_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p15_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p1_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p1_item_type_item_id_idx;


--
-- Name: search_index_p1_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p1_pkey;


--
-- Name: search_index_p1_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p1_searchable_text_idx;


--
-- Name: search_index_p1_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p1_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p1_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p1_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p1_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p1_tenant_id_collective_id_idx;


--
-- Name: search_index_p1_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p1_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p1_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p1_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p1_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p1_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p1_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p1_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p1_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p1_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p2_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p2_item_type_item_id_idx;


--
-- Name: search_index_p2_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p2_pkey;


--
-- Name: search_index_p2_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p2_searchable_text_idx;


--
-- Name: search_index_p2_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p2_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p2_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p2_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p2_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p2_tenant_id_collective_id_idx;


--
-- Name: search_index_p2_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p2_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p2_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p2_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p2_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p2_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p2_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p2_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p2_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p2_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p3_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p3_item_type_item_id_idx;


--
-- Name: search_index_p3_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p3_pkey;


--
-- Name: search_index_p3_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p3_searchable_text_idx;


--
-- Name: search_index_p3_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p3_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p3_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p3_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p3_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p3_tenant_id_collective_id_idx;


--
-- Name: search_index_p3_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p3_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p3_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p3_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p3_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p3_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p3_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p3_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p3_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p3_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p4_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p4_item_type_item_id_idx;


--
-- Name: search_index_p4_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p4_pkey;


--
-- Name: search_index_p4_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p4_searchable_text_idx;


--
-- Name: search_index_p4_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p4_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p4_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p4_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p4_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p4_tenant_id_collective_id_idx;


--
-- Name: search_index_p4_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p4_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p4_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p4_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p4_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p4_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p4_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p4_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p4_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p4_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p5_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p5_item_type_item_id_idx;


--
-- Name: search_index_p5_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p5_pkey;


--
-- Name: search_index_p5_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p5_searchable_text_idx;


--
-- Name: search_index_p5_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p5_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p5_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p5_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p5_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p5_tenant_id_collective_id_idx;


--
-- Name: search_index_p5_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p5_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p5_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p5_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p5_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p5_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p5_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p5_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p5_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p5_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p6_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p6_item_type_item_id_idx;


--
-- Name: search_index_p6_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p6_pkey;


--
-- Name: search_index_p6_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p6_searchable_text_idx;


--
-- Name: search_index_p6_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p6_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p6_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p6_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p6_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p6_tenant_id_collective_id_idx;


--
-- Name: search_index_p6_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p6_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p6_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p6_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p6_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p6_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p6_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p6_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p6_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p6_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p7_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p7_item_type_item_id_idx;


--
-- Name: search_index_p7_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p7_pkey;


--
-- Name: search_index_p7_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p7_searchable_text_idx;


--
-- Name: search_index_p7_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p7_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p7_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p7_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p7_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p7_tenant_id_collective_id_idx;


--
-- Name: search_index_p7_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p7_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p7_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p7_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p7_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p7_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p7_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p7_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p7_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p7_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p8_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p8_item_type_item_id_idx;


--
-- Name: search_index_p8_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p8_pkey;


--
-- Name: search_index_p8_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p8_searchable_text_idx;


--
-- Name: search_index_p8_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p8_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p8_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p8_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p8_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p8_tenant_id_collective_id_idx;


--
-- Name: search_index_p8_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p8_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p8_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p8_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p8_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p8_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p8_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p8_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p8_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p8_tenant_id_replying_to_id_idx;


--
-- Name: search_index_p9_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_item ATTACH PARTITION public.search_index_p9_item_type_item_id_idx;


--
-- Name: search_index_p9_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.search_index_partitioned_pkey ATTACH PARTITION public.search_index_p9_pkey;


--
-- Name: search_index_p9_searchable_text_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_trigram ATTACH PARTITION public.search_index_p9_searchable_text_idx;


--
-- Name: search_index_p9_tenant_id_collective_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_created ATTACH PARTITION public.search_index_p9_tenant_id_collective_id_created_at_idx;


--
-- Name: search_index_p9_tenant_id_collective_id_deadline_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_deadline ATTACH PARTITION public.search_index_p9_tenant_id_collective_id_deadline_idx;


--
-- Name: search_index_p9_tenant_id_collective_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_tenant_collective ATTACH PARTITION public.search_index_p9_tenant_id_collective_id_idx;


--
-- Name: search_index_p9_tenant_id_collective_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_type ATTACH PARTITION public.search_index_p9_tenant_id_collective_id_item_type_idx;


--
-- Name: search_index_p9_tenant_id_collective_id_sort_key_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_cursor ATTACH PARTITION public.search_index_p9_tenant_id_collective_id_sort_key_idx;


--
-- Name: search_index_p9_tenant_id_collective_id_subtype_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_subtype ATTACH PARTITION public.search_index_p9_tenant_id_collective_id_subtype_idx;


--
-- Name: search_index_p9_tenant_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_unique_item ATTACH PARTITION public.search_index_p9_tenant_id_item_type_item_id_idx;


--
-- Name: search_index_p9_tenant_id_replying_to_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_search_index_replying_to ATTACH PARTITION public.search_index_p9_tenant_id_replying_to_id_idx;


--
-- Name: user_item_status_p0_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p0_pkey;


--
-- Name: user_item_status_p0_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p0_tenant_id_user_id_idx;


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p0_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p0_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p0_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p0_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p0_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p10_pkey;


--
-- Name: user_item_status_p10_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p10_tenant_id_user_id_idx;


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p10_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p10_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p10_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p10_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p10_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p11_pkey;


--
-- Name: user_item_status_p11_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p11_tenant_id_user_id_idx;


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p11_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p11_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p11_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p11_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p11_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p12_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p12_pkey;


--
-- Name: user_item_status_p12_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p12_tenant_id_user_id_idx;


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p12_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p12_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p12_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p12_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p12_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p13_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p13_pkey;


--
-- Name: user_item_status_p13_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p13_tenant_id_user_id_idx;


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p13_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p13_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p13_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p13_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p13_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p14_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p14_pkey;


--
-- Name: user_item_status_p14_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p14_tenant_id_user_id_idx;


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p14_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p14_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p14_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p14_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p14_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p15_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p15_pkey;


--
-- Name: user_item_status_p15_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p15_tenant_id_user_id_idx;


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p15_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p15_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p15_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p15_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p15_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p1_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p1_pkey;


--
-- Name: user_item_status_p1_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p1_tenant_id_user_id_idx;


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p1_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p1_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p1_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p1_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p1_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p2_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p2_pkey;


--
-- Name: user_item_status_p2_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p2_tenant_id_user_id_idx;


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p2_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p2_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p2_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p2_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p2_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p3_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p3_pkey;


--
-- Name: user_item_status_p3_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p3_tenant_id_user_id_idx;


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p3_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p3_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p3_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p3_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p3_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p4_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p4_pkey;


--
-- Name: user_item_status_p4_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p4_tenant_id_user_id_idx;


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p4_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p4_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p4_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p4_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p4_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p5_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p5_pkey;


--
-- Name: user_item_status_p5_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p5_tenant_id_user_id_idx;


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p5_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p5_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p5_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p5_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p5_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p6_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p6_pkey;


--
-- Name: user_item_status_p6_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p6_tenant_id_user_id_idx;


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p6_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p6_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p6_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p6_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p6_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p7_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p7_pkey;


--
-- Name: user_item_status_p7_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p7_tenant_id_user_id_idx;


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p7_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p7_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p7_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p7_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p7_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p8_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p8_pkey;


--
-- Name: user_item_status_p8_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p8_tenant_id_user_id_idx;


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p8_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p8_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p8_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p8_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p8_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: user_item_status_p9_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.user_item_status_partitioned_pkey ATTACH PARTITION public.user_item_status_p9_pkey;


--
-- Name: user_item_status_p9_tenant_id_user_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_tenant_user ATTACH PARTITION public.user_item_status_p9_tenant_id_user_id_idx;


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unread ATTACH PARTITION public.user_item_status_p9_tenant_id_user_id_item_type_idx;


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_voted ATTACH PARTITION public.user_item_status_p9_tenant_id_user_id_item_type_idx1;


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_idx2; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_not_participating ATTACH PARTITION public.user_item_status_p9_tenant_id_user_id_item_type_idx2;


--
-- Name: user_item_status_p9_tenant_id_user_id_item_type_item_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_user_item_status_unique ATTACH PARTITION public.user_item_status_p9_tenant_id_user_id_item_type_item_id_idx;


--
-- Name: cycle_data_commitments _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.cycle_data_commitments AS
 SELECT c.tenant_id,
    c.collective_id,
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
  GROUP BY c.tenant_id, c.collective_id, c.id;


--
-- Name: cycle_data_decisions _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.cycle_data_decisions AS
 SELECT d.tenant_id,
    d.collective_id,
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
    (count(DISTINCT v.decision_participant_id))::integer AS participant_count,
    (count(DISTINCT v.decision_participant_id))::integer AS voter_count,
    (count(DISTINCT o.id))::integer AS option_count
   FROM ((((public.decisions d
     LEFT JOIN public.votes v ON ((d.id = v.decision_id)))
     LEFT JOIN public.options o ON ((d.id = o.decision_id)))
     LEFT JOIN public.links dl ON (((d.id = dl.from_linkable_id) AND ((dl.from_linkable_type)::text = 'Decision'::text))))
     LEFT JOIN public.links dbl ON (((d.id = dbl.to_linkable_id) AND ((dbl.to_linkable_type)::text = 'Decision'::text))))
  GROUP BY d.tenant_id, d.collective_id, d.id;


--
-- Name: cycle_data_notes _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.cycle_data_notes AS
 SELECT n.tenant_id,
    n.collective_id,
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
  GROUP BY n.tenant_id, n.collective_id, n.id;


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
-- Name: invites fk_rails_07e7bb098b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_07e7bb098b FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: tenants fk_rails_08060e4c1a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT fk_rails_08060e4c1a FOREIGN KEY (main_collective_id) REFERENCES public.collectives(id);


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
-- Name: ai_agent_task_run_resources fk_rails_15c1014d00; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_run_resources
    ADD CONSTRAINT fk_rails_15c1014d00 FOREIGN KEY (ai_agent_task_run_id) REFERENCES public.ai_agent_task_runs(id);


--
-- Name: automation_rules fk_rails_175ea68c06; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT fk_rails_175ea68c06 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: webhook_deliveries fk_rails_17a316be6e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT fk_rails_17a316be6e FOREIGN KEY (automation_rule_run_id) REFERENCES public.automation_rule_runs(id);


--
-- Name: invites fk_rails_19f2570176; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_19f2570176 FOREIGN KEY (invited_user_id) REFERENCES public.users(id);


--
-- Name: automation_rule_run_resources fk_rails_23642e8a45; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_run_resources
    ADD CONSTRAINT fk_rails_23642e8a45 FOREIGN KEY (automation_rule_run_id) REFERENCES public.automation_rule_runs(id);


--
-- Name: votes fk_rails_23f31e4409; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT fk_rails_23f31e4409 FOREIGN KEY (option_id) REFERENCES public.options(id);


--
-- Name: collective_members fk_rails_247e24a571; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collective_members
    ADD CONSTRAINT fk_rails_247e24a571 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: ai_agent_task_runs fk_rails_24b1563887; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_runs
    ADD CONSTRAINT fk_rails_24b1563887 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: invites fk_rails_29373b6d24; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_29373b6d24 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: commitments fk_rails_2b0260c142; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitments
    ADD CONSTRAINT fk_rails_2b0260c142 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: events fk_rails_2c515e778f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_2c515e778f FOREIGN KEY (actor_id) REFERENCES public.users(id);


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
-- Name: collectives fk_rails_3a6c376636; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collectives
    ADD CONSTRAINT fk_rails_3a6c376636 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: options fk_rails_3c650690de; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.options
    ADD CONSTRAINT fk_rails_3c650690de FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: commitment_participants fk_rails_40630ce2d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitment_participants
    ADD CONSTRAINT fk_rails_40630ce2d2 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: automation_rule_runs fk_rails_489983b9e8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_runs
    ADD CONSTRAINT fk_rails_489983b9e8 FOREIGN KEY (triggered_by_event_id) REFERENCES public.events(id);


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
-- Name: automation_rule_runs fk_rails_4e8a3745a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_runs
    ADD CONSTRAINT fk_rails_4e8a3745a1 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: automation_rule_runs fk_rails_505791fa36; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_runs
    ADD CONSTRAINT fk_rails_505791fa36 FOREIGN KEY (automation_rule_id) REFERENCES public.automation_rules(id);


--
-- Name: notification_recipients fk_rails_51975e21a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_recipients
    ADD CONSTRAINT fk_rails_51975e21a8 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: ai_agent_task_runs fk_rails_530eeec9cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_runs
    ADD CONSTRAINT fk_rails_530eeec9cb FOREIGN KEY (initiated_by_id) REFERENCES public.users(id);


--
-- Name: collective_members fk_rails_55c1625b39; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collective_members
    ADD CONSTRAINT fk_rails_55c1625b39 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: note_history_events fk_rails_601d54357c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT fk_rails_601d54357c FOREIGN KEY (note_id) REFERENCES public.notes(id);


--
-- Name: note_history_events fk_rails_63e2a8744d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT fk_rails_63e2a8744d FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: representation_session_events fk_rails_649adaf955; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_events
    ADD CONSTRAINT fk_rails_649adaf955 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: heartbeats fk_rails_65aa64ba75; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeats
    ADD CONSTRAINT fk_rails_65aa64ba75 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: automation_rules fk_rails_67e5475e75; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT fk_rails_67e5475e75 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: events fk_rails_6844d4946c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_6844d4946c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: links fk_rails_6888b30c51; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.links
    ADD CONSTRAINT fk_rails_6888b30c51 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: collective_members fk_rails_6922fe428a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collective_members
    ADD CONSTRAINT fk_rails_6922fe428a FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: invites fk_rails_6dd1026bef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_6dd1026bef FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: notes fk_rails_6e1963e950; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT fk_rails_6e1963e950 FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: notifications fk_rails_78f4b5a537; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_78f4b5a537 FOREIGN KEY (event_id) REFERENCES public.events(id);


--
-- Name: webhook_deliveries fk_rails_7c0bbfdb0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT fk_rails_7c0bbfdb0c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: notifications fk_rails_7c99fe0556; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_7c99fe0556 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: decisions fk_rails_7ee5cf7c37; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT fk_rails_7ee5cf7c37 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: ai_agent_task_run_resources fk_rails_803b260faa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_run_resources
    ADD CONSTRAINT fk_rails_803b260faa FOREIGN KEY (resource_collective_id) REFERENCES public.collectives(id);


--
-- Name: decision_participants fk_rails_81ebc9cc6f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_participants
    ADD CONSTRAINT fk_rails_81ebc9cc6f FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: automation_rules fk_rails_858e51f175; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT fk_rails_858e51f175 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: attachments fk_rails_87cce8e128; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT fk_rails_87cce8e128 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: collectives fk_rails_8d8050599b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collectives
    ADD CONSTRAINT fk_rails_8d8050599b FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: representation_session_events fk_rails_8dca449045; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_events
    ADD CONSTRAINT fk_rails_8dca449045 FOREIGN KEY (resource_collective_id) REFERENCES public.collectives(id);


--
-- Name: automation_rule_runs fk_rails_8dea201cdb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_runs
    ADD CONSTRAINT fk_rails_8dea201cdb FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: representation_session_events fk_rails_901c70e333; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_events
    ADD CONSTRAINT fk_rails_901c70e333 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: automation_rule_run_resources fk_rails_9206dc9615; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_run_resources
    ADD CONSTRAINT fk_rails_9206dc9615 FOREIGN KEY (resource_collective_id) REFERENCES public.collectives(id);


--
-- Name: automation_rules fk_rails_923f8bbd47; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT fk_rails_923f8bbd47 FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: note_history_events fk_rails_927b722124; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_history_events
    ADD CONSTRAINT fk_rails_927b722124 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


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
-- Name: ai_agent_task_run_resources fk_rails_a0e1c6c965; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_run_resources
    ADD CONSTRAINT fk_rails_a0e1c6c965 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


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
-- Name: notification_recipients fk_rails_a8704dfb21; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_recipients
    ADD CONSTRAINT fk_rails_a8704dfb21 FOREIGN KEY (notification_id) REFERENCES public.notifications(id);


--
-- Name: automation_rule_run_resources fk_rails_a9f3201d54; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_run_resources
    ADD CONSTRAINT fk_rails_a9f3201d54 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: events fk_rails_ae2d71ac2b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_ae2d71ac2b FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: commitments fk_rails_ae61a497df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitments
    ADD CONSTRAINT fk_rails_ae61a497df FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: votes fk_rails_ae9f41675e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT fk_rails_ae9f41675e FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: webhook_deliveries fk_rails_b1d1ee2779; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT fk_rails_b1d1ee2779 FOREIGN KEY (event_id) REFERENCES public.events(id);


--
-- Name: ai_agent_task_runs fk_rails_b553b9912c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_runs
    ADD CONSTRAINT fk_rails_b553b9912c FOREIGN KEY (ai_agent_id) REFERENCES public.users(id);


--
-- Name: ai_agent_task_runs fk_rails_c09b289302; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_task_runs
    ADD CONSTRAINT fk_rails_c09b289302 FOREIGN KEY (automation_rule_id) REFERENCES public.automation_rules(id);


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
-- Name: trustee_grants fk_rails_c85c161771; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_grants
    ADD CONSTRAINT fk_rails_c85c161771 FOREIGN KEY (trustee_user_id) REFERENCES public.users(id);


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
-- Name: automation_rules fk_rails_cf6a0dd51b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT fk_rails_cf6a0dd51b FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: representation_sessions fk_rails_d99c283120; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_sessions
    ADD CONSTRAINT fk_rails_d99c283120 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


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
-- Name: trustee_grants fk_rails_dc3eb15db3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_grants
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
-- Name: trustee_grants fk_rails_e32a8a6734; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trustee_grants
    ADD CONSTRAINT fk_rails_e32a8a6734 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


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
-- Name: heartbeats fk_rails_ef017bd5f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.heartbeats
    ADD CONSTRAINT fk_rails_ef017bd5f0 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


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
    ADD CONSTRAINT fk_rails_f11a0907b0 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: api_tokens fk_rails_f16b5e0447; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT fk_rails_f16b5e0447 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: notification_recipients fk_rails_f4bcceedb3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_recipients
    ADD CONSTRAINT fk_rails_f4bcceedb3 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: commitment_participants fk_rails_f513f0d5dd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commitment_participants
    ADD CONSTRAINT fk_rails_f513f0d5dd FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: decision_participants fk_rails_f9c15d4765; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_participants
    ADD CONSTRAINT fk_rails_f9c15d4765 FOREIGN KEY (collective_id) REFERENCES public.collectives(id);


--
-- Name: collectives fk_rails_fbb5f3e2b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collectives
    ADD CONSTRAINT fk_rails_fbb5f3e2b8 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: automation_rule_runs fk_rails_fc1435e77b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rule_runs
    ADD CONSTRAINT fk_rails_fc1435e77b FOREIGN KEY (ai_agent_task_run_id) REFERENCES public.ai_agent_task_runs(id);


--
-- Name: automation_rules fk_rails_fdf6ac9d56; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT fk_rails_fdf6ac9d56 FOREIGN KEY (ai_agent_id) REFERENCES public.users(id);


--
-- Name: representation_sessions fk_rails_fe74e74f22; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_sessions
    ADD CONSTRAINT fk_rails_fe74e74f22 FOREIGN KEY (trustee_grant_id) REFERENCES public.trustee_grants(id);


--
-- Name: representation_session_events fk_rails_fe84af3d85; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.representation_session_events
    ADD CONSTRAINT fk_rails_fe84af3d85 FOREIGN KEY (representation_session_id) REFERENCES public.representation_sessions(id);


--
-- PostgreSQL database dump complete
--

\unrestrict guCJPruAdnheuOfGgbG1Ga41uSKeX6dLG3fgtXWDem9t4WsW46OnjNlhdEHYj8p

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
('20260110023045'),
('20260111021536'),
('20260111021537'),
('20260111021538'),
('20260111113813'),
('20260111113916'),
('20260111124237'),
('20260112131013'),
('20260115044701'),
('20260115180000'),
('20260116180713'),
('20260116180721'),
('20260116180725'),
('20260123021234'),
('20260123023618'),
('20260123023658'),
('20260125063251'),
('20260125064500'),
('20260128052404'),
('20260128072608'),
('20260128200000'),
('20260128232615'),
('20260129083556'),
('20260129084357'),
('20260130063701'),
('20260130190512'),
('20260130193043'),
('20260130194543'),
('20260130204044'),
('20260131000001'),
('20260131000002'),
('20260201143513'),
('20260202052258'),
('20260203032407'),
('20260203044904'),
('20260203055419'),
('20260204110122'),
('20260205034909'),
('20260206051044'),
('20260206052934'),
('20260206194042'),
('20260206214518'),
('20260207001008'),
('20260207085452'),
('20260207141046'),
('20260208044921'),
('20260208054634'),
('20260208112506'),
('20260208234822'),
('20260209000000'),
('20260209231143'),
('20260210000001'),
('20260210000002'),
('20260210000003'),
('20260210234230'),
('20260211114428'),
('20260211200000'),
('20260211200001'),
('20260211200002'),
('20260212062528'),
('20260212212340'),
('20260214192742'),
('20260214205415'),
('20260214205558'),
('20260214210049'),
('20260215202823'),
('20260216154858'),
('20260217142214');


