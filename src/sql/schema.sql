--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4 (Ubuntu 17.4-1.pgdg24.04+2)
-- Dumped by pg_dump version 17.4 (Ubuntu 17.4-1.pgdg24.04+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: archive; Type: SCHEMA; Schema: -; Owner: georgios
--

CREATE SCHEMA archive;


ALTER SCHEMA archive OWNER TO georgios;

--
-- Name: pg_cron; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION pg_cron; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_cron IS 'Job scheduler for PostgreSQL';


--
-- Name: osm_raw_data; Type: SCHEMA; Schema: -; Owner: georgios
--

CREATE SCHEMA osm_raw_data;


ALTER SCHEMA osm_raw_data OWNER TO georgios;

--
-- Name: osm_routing_data; Type: SCHEMA; Schema: -; Owner: georgios
--

CREATE SCHEMA osm_routing_data;


ALTER SCHEMA osm_routing_data OWNER TO georgios;

--
-- Name: SCHEMA osm_routing_data; Type: COMMENT; Schema: -; Owner: georgios
--

COMMENT ON SCHEMA osm_routing_data IS 'Raw data from pgrouting import tool';


--
-- Name: v1_0_0; Type: SCHEMA; Schema: -; Owner: georgios
--

CREATE SCHEMA v1_0_0;


ALTER SCHEMA v1_0_0 OWNER TO georgios;

--
-- Name: SCHEMA v1_0_0; Type: COMMENT; Schema: -; Owner: georgios
--

COMMENT ON SCHEMA v1_0_0 IS 'Version 1.0.0 of the application interface';


--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';


--
-- Name: pgrouting; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgrouting WITH SCHEMA public;


--
-- Name: EXTENSION pgrouting; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgrouting IS 'pgRouting Extension';


--
-- Name: emergency_state_enum; Type: TYPE; Schema: public; Owner: georgios
--

CREATE TYPE public.emergency_state_enum AS ENUM (
    'declared',
    'active',
    'concluded'
);


ALTER TYPE public.emergency_state_enum OWNER TO georgios;

--
-- Name: TYPE emergency_state_enum; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TYPE public.emergency_state_enum IS 'This enumerated type represents possible states \
	 of an emergency';


--
-- Name: emergency_vehicles_enum; Type: TYPE; Schema: public; Owner: georgios
--

CREATE TYPE public.emergency_vehicles_enum AS ENUM (
    'attached',
    'detached'
);


ALTER TYPE public.emergency_vehicles_enum OWNER TO georgios;

--
-- Name: TYPE emergency_vehicles_enum; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TYPE public.emergency_vehicles_enum IS 'This enumerated type represents possible states \
	 of a vehicle taking part in an emergency';


--
-- Name: vehicle_state_enum; Type: TYPE; Schema: public; Owner: georgios
--

CREATE TYPE public.vehicle_state_enum AS ENUM (
    'commissioned',
    'decommissioned',
    'on duty',
    'off duty',
    'assigned'
);


ALTER TYPE public.vehicle_state_enum OWNER TO georgios;

--
-- Name: TYPE vehicle_state_enum; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TYPE public.vehicle_state_enum IS 'This enumerated type represents possible states \
	 of a vehicle in the fleet';


--
-- Name: fn_conclude_emergency(); Type: FUNCTION; Schema: public; Owner: georgios
--

CREATE FUNCTION public.fn_conclude_emergency() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	rec	record;
BEGIN
	FOR rec IN
		SELECT
			ev.vehicle_id,
			v.fleet_id
		FROM
			emergency_vehicles AS ev JOIN
			vehicles v ON (
				ev.vehicle_id = v.id
			)
		WHERE
			(ev.vehicle_id, ev.timestamp) IN (
				SELECT
					vehicle_id,
					MAX(timestamp)
				FROM
					emergency_vehicles
				WHERE
					emergency_id = NEW.emergency_id
				GROUP BY
					vehicle_id
			) AND 
			ev.status = 'attached'
	LOOP
		RAISE NOTICE 'Vehicle with fleet_id % will be automatically detached from emergency %', rec.fleet_id, NEW.emergency_id;
		INSERT INTO
			emergency_vehicles (emergency_id, vehicle_id, status)
		VALUES
			(NEW.emergency_id, rec.vehicle_id, 'detached');
	END LOOP;
	RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_conclude_emergency() OWNER TO georgios;

--
-- Name: fn_emergency_initial_state(); Type: FUNCTION; Schema: public; Owner: georgios
--

CREATE FUNCTION public.fn_emergency_initial_state() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	INSERT INTO
		emergency_state (emergency_id, state)
	VALUES
		(NEW.id, 'declared');
	RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_emergency_initial_state() OWNER TO georgios;

--
-- Name: fn_emergency_vehicle_status(); Type: FUNCTION; Schema: public; Owner: georgios
--

CREATE FUNCTION public.fn_emergency_vehicle_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	vehicle_state_var vehicle_state%ROWTYPE;
BEGIN
	SELECT
		*
	INTO
		vehicle_state_var
	FROM
		vehicle_state
	WHERE
		vehicle_id = NEW.vehicle_id
	ORDER BY
		timestamp DESC
	LIMIT
		1;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Vehicle (%) has no state', NEW.vehicle_id;
	ELSIF vehicle_state_var.state != 'on duty' AND NEW.status = 'attached' THEN
		RAISE EXCEPTION 'Vehicle (%) has invalid state (%)', NEW.vehicle_id, vehicle_state_var.state
			USING HINT = 'Valid state is "on duty"';
	ELSIF vehicle_state_var.state != 'assigned' AND NEW.status = 'detached' THEN
		RAISE EXCEPTION 'Vehicle (%) has invalid state (%)', NEW.vehicle_id, vehicle_state_var.state
			USING HINT = 'Valid state is "assigned"';
	END IF;

	INSERT INTO
		vehicle_state (vehicle_id, state)
	VALUES (
		NEW.vehicle_id,
		(CASE
			WHEN NEW.status = 'attached' THEN 'assigned'
		ELSE
			'on duty'
		END)::vehicle_state_enum
	);

	RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_emergency_vehicle_status() OWNER TO georgios;

--
-- Name: fn_location_check(); Type: FUNCTION; Schema: public; Owner: georgios
--

CREATE FUNCTION public.fn_location_check() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	check_way osm_raw_data.planet_osm_polygon.way%TYPE;
BEGIN
	SELECT
		way INTO check_way
	FROM
		osm_raw_data.planet_osm_polygon
	WHERE
		name = 'Λέσβος' AND
		place = 'island';
 
	IF NOT ST_Contains(check_way, NEW.location) THEN
		RAISE EXCEPTION 'Location (%) out of bounds', ST_AsText(NEW.location)
			USING HINT = 'Please check that the location is within Lesvos';
	END IF;
	RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_location_check() OWNER TO georgios;

--
-- Name: fn_vehicle_initial_state(); Type: FUNCTION; Schema: public; Owner: georgios
--

CREATE FUNCTION public.fn_vehicle_initial_state() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	INSERT INTO
		vehicle_state (vehicle_id, state)
	VALUES
		(NEW.id, 'commissioned');
	RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_vehicle_initial_state() OWNER TO georgios;

--
-- Name: fn_vehicle_location_archive(); Type: FUNCTION; Schema: public; Owner: georgios
--

CREATE FUNCTION public.fn_vehicle_location_archive() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	INSERT INTO
		archive.vehicle_location
	VALUES
		(OLD.*);
	RETURN OLD;
END;
$$;


ALTER FUNCTION public.fn_vehicle_location_archive() OWNER TO georgios;

--
-- Name: assign_vehicle_location(text, public.geometry); Type: FUNCTION; Schema: v1_0_0; Owner: georgios
--

CREATE FUNCTION v1_0_0.assign_vehicle_location(in_fleet_id text, in_location public.geometry) RETURNS bigint
    LANGUAGE sql
    AS $$
	INSERT INTO
		public.vehicle_location (vehicle_id, location)
	SELECT
		id,
		ST_Transform(in_location,2100)
	FROM
		vehicles
	WHERE
		fleet_id = in_fleet_id
	RETURNING
		location_id;
$$;


ALTER FUNCTION v1_0_0.assign_vehicle_location(in_fleet_id text, in_location public.geometry) OWNER TO georgios;

--
-- Name: assign_vehicle_state(text, public.vehicle_state_enum); Type: FUNCTION; Schema: v1_0_0; Owner: georgios
--

CREATE FUNCTION v1_0_0.assign_vehicle_state(in_fleet_id text, in_state public.vehicle_state_enum) RETURNS integer
    LANGUAGE sql
    AS $$
	INSERT INTO
		public.vehicle_state (vehicle_id, state)
	VALUES (
		(SELECT id FROM public.vehicles WHERE fleet_id = in_fleet_id),
		in_state
	)
	RETURNING
		state_id;
$$;


ALTER FUNCTION v1_0_0.assign_vehicle_state(in_fleet_id text, in_state public.vehicle_state_enum) OWNER TO georgios;

--
-- Name: available_eta(integer); Type: FUNCTION; Schema: v1_0_0; Owner: georgios
--

CREATE FUNCTION v1_0_0.available_eta(emergency_vid integer) RETURNS TABLE(fleet_id character varying, "ETA" double precision, "human readable ETA" character varying)
    LANGUAGE sql
    AS $$
WITH available AS (
	SELECT
		*
	FROM
		v1_0_0.vehicle_latest_info
	WHERE
		state = 'on duty'
), osm_ids AS (
	SELECT
		available.fleet_id,
		available.location,
		nearest.id AS node_id
	FROM
		available
	JOIN LATERAL (
		SELECT
			vertex.id
		FROM
			osm_routing_data.ways_vertices_pgr vertex
		ORDER BY
			vertex.the_geom <-> available.location
		LIMIT 1
	) AS nearest ON
		true
), dijkstra AS (
	SELECT
		*
	FROM
		pgr_dijkstra(
		'
			SELECT
				gid AS id,
				source,
				target,
				cost_s AS cost,
				reverse_cost_s AS reverse_cost
			FROM
				osm_routing_data.ways
		',
		(SELECT ARRAY_AGG(node_id) FROM osm_ids),	-- Available vehicle's vertices
		emergency_vid,							    -- Emergency vertex
		directed := true
	)
)
SELECT
	osm_ids.fleet_id,
	MAX(dijkstra.agg_cost) AS ETA,
	TO_CHAR((MAX(dijkstra.agg_cost) || ' second')::interval, 'HH24:MI:SS') AS "human readable ETA"
FROM
	dijkstra
JOIN
	osm_ids ON
		dijkstra.start_vid = osm_ids.node_id
GROUP BY
	osm_ids.fleet_id
ORDER BY
	ETA ASC
$$;


ALTER FUNCTION v1_0_0.available_eta(emergency_vid integer) OWNER TO georgios;

--
-- Name: delete_vehicle(text); Type: FUNCTION; Schema: v1_0_0; Owner: georgios
--

CREATE FUNCTION v1_0_0.delete_vehicle(in_fleet_id text) RETURNS integer
    LANGUAGE sql
    AS $$
   DELETE FROM 
        public.vehicles 
	WHERE
        in_fleet_id = in_fleet_id
    RETURNING
        id;
$$;


ALTER FUNCTION v1_0_0.delete_vehicle(in_fleet_id text) OWNER TO georgios;

--
-- Name: insert_vehicle(text); Type: FUNCTION; Schema: v1_0_0; Owner: georgios
--

CREATE FUNCTION v1_0_0.insert_vehicle(in_fleet_id text) RETURNS integer
    LANGUAGE sql
    AS $$
    INSERT INTO
        public.vehicles (fleet_id)
    VALUES (
        in_fleet_id
    )
    RETURNING
        id;
$$;


ALTER FUNCTION v1_0_0.insert_vehicle(in_fleet_id text) OWNER TO georgios;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: vehicle_location; Type: TABLE; Schema: archive; Owner: georgios
--

CREATE TABLE archive.vehicle_location (
    location_id bigint NOT NULL,
    vehicle_id integer NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    location public.geometry(Point,2100) NOT NULL
);


ALTER TABLE archive.vehicle_location OWNER TO georgios;

--
-- Name: TABLE vehicle_location; Type: COMMENT; Schema: archive; Owner: georgios
--

COMMENT ON TABLE archive.vehicle_location IS 'Historical entries of vehicle_location table';


--
-- Name: osm2pgsql_properties; Type: TABLE; Schema: osm_raw_data; Owner: georgios
--

CREATE TABLE osm_raw_data.osm2pgsql_properties (
    property text NOT NULL,
    value text NOT NULL
);


ALTER TABLE osm_raw_data.osm2pgsql_properties OWNER TO georgios;

--
-- Name: planet_osm_line; Type: TABLE; Schema: osm_raw_data; Owner: georgios
--

CREATE TABLE osm_raw_data.planet_osm_line (
    osm_id bigint,
    access text,
    "addr:housename" text,
    "addr:housenumber" text,
    "addr:interpolation" text,
    admin_level text,
    aerialway text,
    aeroway text,
    amenity text,
    area text,
    barrier text,
    bicycle text,
    brand text,
    bridge text,
    boundary text,
    building text,
    construction text,
    covered text,
    culvert text,
    cutting text,
    denomination text,
    disused text,
    embankment text,
    foot text,
    "generator:source" text,
    harbour text,
    highway text,
    historic text,
    horse text,
    intermittent text,
    junction text,
    landuse text,
    layer text,
    leisure text,
    lock text,
    man_made text,
    military text,
    motorcar text,
    name text,
    "natural" text,
    office text,
    oneway text,
    operator text,
    place text,
    population text,
    power text,
    power_source text,
    public_transport text,
    railway text,
    ref text,
    religion text,
    route text,
    service text,
    shop text,
    sport text,
    surface text,
    toll text,
    tourism text,
    "tower:type" text,
    tracktype text,
    tunnel text,
    water text,
    waterway text,
    wetland text,
    width text,
    wood text,
    z_order integer,
    way_area real,
    way public.geometry(LineString,2100)
);


ALTER TABLE osm_raw_data.planet_osm_line OWNER TO georgios;

--
-- Name: planet_osm_point; Type: TABLE; Schema: osm_raw_data; Owner: georgios
--

CREATE TABLE osm_raw_data.planet_osm_point (
    osm_id bigint,
    access text,
    "addr:housename" text,
    "addr:housenumber" text,
    "addr:interpolation" text,
    admin_level text,
    aerialway text,
    aeroway text,
    amenity text,
    area text,
    barrier text,
    bicycle text,
    brand text,
    bridge text,
    boundary text,
    building text,
    capital text,
    construction text,
    covered text,
    culvert text,
    cutting text,
    denomination text,
    disused text,
    ele text,
    embankment text,
    foot text,
    "generator:source" text,
    harbour text,
    highway text,
    historic text,
    horse text,
    intermittent text,
    junction text,
    landuse text,
    layer text,
    leisure text,
    lock text,
    man_made text,
    military text,
    motorcar text,
    name text,
    "natural" text,
    office text,
    oneway text,
    operator text,
    place text,
    population text,
    power text,
    power_source text,
    public_transport text,
    railway text,
    ref text,
    religion text,
    route text,
    service text,
    shop text,
    sport text,
    surface text,
    toll text,
    tourism text,
    "tower:type" text,
    tunnel text,
    water text,
    waterway text,
    wetland text,
    width text,
    wood text,
    z_order integer,
    way public.geometry(Point,2100)
);


ALTER TABLE osm_raw_data.planet_osm_point OWNER TO georgios;

--
-- Name: planet_osm_polygon; Type: TABLE; Schema: osm_raw_data; Owner: georgios
--

CREATE TABLE osm_raw_data.planet_osm_polygon (
    osm_id bigint,
    access text,
    "addr:housename" text,
    "addr:housenumber" text,
    "addr:interpolation" text,
    admin_level text,
    aerialway text,
    aeroway text,
    amenity text,
    area text,
    barrier text,
    bicycle text,
    brand text,
    bridge text,
    boundary text,
    building text,
    construction text,
    covered text,
    culvert text,
    cutting text,
    denomination text,
    disused text,
    embankment text,
    foot text,
    "generator:source" text,
    harbour text,
    highway text,
    historic text,
    horse text,
    intermittent text,
    junction text,
    landuse text,
    layer text,
    leisure text,
    lock text,
    man_made text,
    military text,
    motorcar text,
    name text,
    "natural" text,
    office text,
    oneway text,
    operator text,
    place text,
    population text,
    power text,
    power_source text,
    public_transport text,
    railway text,
    ref text,
    religion text,
    route text,
    service text,
    shop text,
    sport text,
    surface text,
    toll text,
    tourism text,
    "tower:type" text,
    tracktype text,
    tunnel text,
    water text,
    waterway text,
    wetland text,
    width text,
    wood text,
    z_order integer,
    way_area real,
    way public.geometry(Geometry,2100)
);


ALTER TABLE osm_raw_data.planet_osm_polygon OWNER TO georgios;

--
-- Name: planet_osm_roads; Type: TABLE; Schema: osm_raw_data; Owner: georgios
--

CREATE TABLE osm_raw_data.planet_osm_roads (
    osm_id bigint,
    access text,
    "addr:housename" text,
    "addr:housenumber" text,
    "addr:interpolation" text,
    admin_level text,
    aerialway text,
    aeroway text,
    amenity text,
    area text,
    barrier text,
    bicycle text,
    brand text,
    bridge text,
    boundary text,
    building text,
    construction text,
    covered text,
    culvert text,
    cutting text,
    denomination text,
    disused text,
    embankment text,
    foot text,
    "generator:source" text,
    harbour text,
    highway text,
    historic text,
    horse text,
    intermittent text,
    junction text,
    landuse text,
    layer text,
    leisure text,
    lock text,
    man_made text,
    military text,
    motorcar text,
    name text,
    "natural" text,
    office text,
    oneway text,
    operator text,
    place text,
    population text,
    power text,
    power_source text,
    public_transport text,
    railway text,
    ref text,
    religion text,
    route text,
    service text,
    shop text,
    sport text,
    surface text,
    toll text,
    tourism text,
    "tower:type" text,
    tracktype text,
    tunnel text,
    water text,
    waterway text,
    wetland text,
    width text,
    wood text,
    z_order integer,
    way_area real,
    way public.geometry(LineString,2100)
);


ALTER TABLE osm_raw_data.planet_osm_roads OWNER TO georgios;

--
-- Name: configuration; Type: TABLE; Schema: osm_routing_data; Owner: georgios
--

CREATE TABLE osm_routing_data.configuration (
    id integer NOT NULL,
    tag_id integer,
    tag_key text,
    tag_value text,
    priority double precision,
    maxspeed double precision,
    maxspeed_forward double precision,
    maxspeed_backward double precision,
    force character(1)
)
WITH (autovacuum_enabled='false');


ALTER TABLE osm_routing_data.configuration OWNER TO georgios;

--
-- Name: configuration_id_seq; Type: SEQUENCE; Schema: osm_routing_data; Owner: georgios
--

CREATE SEQUENCE osm_routing_data.configuration_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE osm_routing_data.configuration_id_seq OWNER TO georgios;

--
-- Name: configuration_id_seq; Type: SEQUENCE OWNED BY; Schema: osm_routing_data; Owner: georgios
--

ALTER SEQUENCE osm_routing_data.configuration_id_seq OWNED BY osm_routing_data.configuration.id;


--
-- Name: pointsofinterest; Type: TABLE; Schema: osm_routing_data; Owner: georgios
--

CREATE TABLE osm_routing_data.pointsofinterest (
    pid bigint NOT NULL,
    osm_id bigint,
    vertex_id bigint,
    edge_id bigint,
    side character(1),
    fraction double precision,
    length_m double precision,
    tag_name text,
    tag_value text,
    name text,
    the_geom public.geometry(Point,4326),
    new_geom public.geometry(Point,4326)
)
WITH (autovacuum_enabled='false');


ALTER TABLE osm_routing_data.pointsofinterest OWNER TO georgios;

--
-- Name: pointsofinterest_pid_seq; Type: SEQUENCE; Schema: osm_routing_data; Owner: georgios
--

CREATE SEQUENCE osm_routing_data.pointsofinterest_pid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE osm_routing_data.pointsofinterest_pid_seq OWNER TO georgios;

--
-- Name: pointsofinterest_pid_seq; Type: SEQUENCE OWNED BY; Schema: osm_routing_data; Owner: georgios
--

ALTER SEQUENCE osm_routing_data.pointsofinterest_pid_seq OWNED BY osm_routing_data.pointsofinterest.pid;


--
-- Name: ways; Type: TABLE; Schema: osm_routing_data; Owner: georgios
--

CREATE TABLE osm_routing_data.ways (
    gid bigint NOT NULL,
    osm_id bigint,
    tag_id integer,
    length double precision,
    length_m double precision,
    name text,
    source bigint,
    target bigint,
    source_osm bigint,
    target_osm bigint,
    cost double precision,
    reverse_cost double precision,
    cost_s double precision,
    reverse_cost_s double precision,
    rule text,
    one_way integer,
    oneway text,
    x1 double precision,
    y1 double precision,
    x2 double precision,
    y2 double precision,
    maxspeed_forward double precision,
    maxspeed_backward double precision,
    priority double precision DEFAULT 1,
    the_geom public.geometry(LineString,2100)
)
WITH (autovacuum_enabled='false');


ALTER TABLE osm_routing_data.ways OWNER TO georgios;

--
-- Name: ways_gid_seq; Type: SEQUENCE; Schema: osm_routing_data; Owner: georgios
--

CREATE SEQUENCE osm_routing_data.ways_gid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE osm_routing_data.ways_gid_seq OWNER TO georgios;

--
-- Name: ways_gid_seq; Type: SEQUENCE OWNED BY; Schema: osm_routing_data; Owner: georgios
--

ALTER SEQUENCE osm_routing_data.ways_gid_seq OWNED BY osm_routing_data.ways.gid;


--
-- Name: ways_vertices_pgr; Type: TABLE; Schema: osm_routing_data; Owner: georgios
--

CREATE TABLE osm_routing_data.ways_vertices_pgr (
    id bigint NOT NULL,
    osm_id bigint,
    eout integer,
    lon numeric(11,8),
    lat numeric(11,8),
    cnt integer,
    chk integer,
    ein integer,
    the_geom public.geometry(Point,2100)
)
WITH (autovacuum_enabled='false');


ALTER TABLE osm_routing_data.ways_vertices_pgr OWNER TO georgios;

--
-- Name: ways_vertices_pgr_id_seq; Type: SEQUENCE; Schema: osm_routing_data; Owner: georgios
--

CREATE SEQUENCE osm_routing_data.ways_vertices_pgr_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE osm_routing_data.ways_vertices_pgr_id_seq OWNER TO georgios;

--
-- Name: ways_vertices_pgr_id_seq; Type: SEQUENCE OWNED BY; Schema: osm_routing_data; Owner: georgios
--

ALTER SEQUENCE osm_routing_data.ways_vertices_pgr_id_seq OWNED BY osm_routing_data.ways_vertices_pgr.id;


--
-- Name: emergencies; Type: TABLE; Schema: public; Owner: georgios
--

CREATE TABLE public.emergencies (
    id integer NOT NULL,
    location public.geometry(Point,2100) NOT NULL,
    description text NOT NULL
);


ALTER TABLE public.emergencies OWNER TO georgios;

--
-- Name: TABLE emergencies; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TABLE public.emergencies IS 'Base relation for emergencies';


--
-- Name: emergencies_id_seq; Type: SEQUENCE; Schema: public; Owner: georgios
--

CREATE SEQUENCE public.emergencies_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.emergencies_id_seq OWNER TO georgios;

--
-- Name: emergencies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: georgios
--

ALTER SEQUENCE public.emergencies_id_seq OWNED BY public.emergencies.id;


--
-- Name: emergency_state; Type: TABLE; Schema: public; Owner: georgios
--

CREATE TABLE public.emergency_state (
    state_id integer NOT NULL,
    emergency_id integer NOT NULL,
    "timestamp" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    state public.emergency_state_enum NOT NULL
);


ALTER TABLE public.emergency_state OWNER TO georgios;

--
-- Name: TABLE emergency_state; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TABLE public.emergency_state IS 'A log for the state of each emergency at a given time';


--
-- Name: emergency_state_state_id_seq; Type: SEQUENCE; Schema: public; Owner: georgios
--

CREATE SEQUENCE public.emergency_state_state_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.emergency_state_state_id_seq OWNER TO georgios;

--
-- Name: emergency_state_state_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: georgios
--

ALTER SEQUENCE public.emergency_state_state_id_seq OWNED BY public.emergency_state.state_id;


--
-- Name: emergency_vehicles; Type: TABLE; Schema: public; Owner: georgios
--

CREATE TABLE public.emergency_vehicles (
    id integer NOT NULL,
    emergency_id integer NOT NULL,
    vehicle_id integer NOT NULL,
    "timestamp" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status public.emergency_vehicles_enum NOT NULL
);


ALTER TABLE public.emergency_vehicles OWNER TO georgios;

--
-- Name: TABLE emergency_vehicles; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TABLE public.emergency_vehicles IS 'A log for the vehicles assigned on an emergency at a given time';


--
-- Name: emergency_vehicles_id_seq; Type: SEQUENCE; Schema: public; Owner: georgios
--

CREATE SEQUENCE public.emergency_vehicles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.emergency_vehicles_id_seq OWNER TO georgios;

--
-- Name: emergency_vehicles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: georgios
--

ALTER SEQUENCE public.emergency_vehicles_id_seq OWNED BY public.emergency_vehicles.id;


--
-- Name: vehicle_location; Type: TABLE; Schema: public; Owner: georgios
--

CREATE TABLE public.vehicle_location (
    location_id bigint NOT NULL,
    vehicle_id integer NOT NULL,
    "timestamp" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    location public.geometry(Point,2100) NOT NULL
);


ALTER TABLE public.vehicle_location OWNER TO georgios;

--
-- Name: TABLE vehicle_location; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TABLE public.vehicle_location IS 'A log for the location of each vehicle at a given time';


--
-- Name: vehicle_location_location_id_seq; Type: SEQUENCE; Schema: public; Owner: georgios
--

CREATE SEQUENCE public.vehicle_location_location_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vehicle_location_location_id_seq OWNER TO georgios;

--
-- Name: vehicle_location_location_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: georgios
--

ALTER SEQUENCE public.vehicle_location_location_id_seq OWNED BY public.vehicle_location.location_id;


--
-- Name: vehicle_state; Type: TABLE; Schema: public; Owner: georgios
--

CREATE TABLE public.vehicle_state (
    state_id integer NOT NULL,
    vehicle_id integer NOT NULL,
    "timestamp" timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    state public.vehicle_state_enum NOT NULL
);


ALTER TABLE public.vehicle_state OWNER TO georgios;

--
-- Name: TABLE vehicle_state; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TABLE public.vehicle_state IS 'A log for the state of each vehicle at a given time';


--
-- Name: vehicle_state_state_id_seq; Type: SEQUENCE; Schema: public; Owner: georgios
--

CREATE SEQUENCE public.vehicle_state_state_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vehicle_state_state_id_seq OWNER TO georgios;

--
-- Name: vehicle_state_state_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: georgios
--

ALTER SEQUENCE public.vehicle_state_state_id_seq OWNED BY public.vehicle_state.state_id;


--
-- Name: vehicles; Type: TABLE; Schema: public; Owner: georgios
--

CREATE TABLE public.vehicles (
    id integer NOT NULL,
    fleet_id character varying(8) NOT NULL,
    CONSTRAINT valid_fleet_identifier CHECK (((fleet_id)::text ~ '^[A-Z]{3}-[0-9]{3}$'::text))
);


ALTER TABLE public.vehicles OWNER TO georgios;

--
-- Name: TABLE vehicles; Type: COMMENT; Schema: public; Owner: georgios
--

COMMENT ON TABLE public.vehicles IS 'Base relation for vehicles';


--
-- Name: vehicles_id_seq; Type: SEQUENCE; Schema: public; Owner: georgios
--

CREATE SEQUENCE public.vehicles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vehicles_id_seq OWNER TO georgios;

--
-- Name: vehicles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: georgios
--

ALTER SEQUENCE public.vehicles_id_seq OWNED BY public.vehicles.id;


--
-- Name: vehicle_info; Type: VIEW; Schema: v1_0_0; Owner: georgios
--

CREATE VIEW v1_0_0.vehicle_info AS
 WITH state_info AS (
         SELECT vehicle_state.vehicle_id,
            vehicle_state.state,
            vehicle_state."timestamp" AS start_timestamp,
            COALESCE(lead(vehicle_state."timestamp", 1) OVER (PARTITION BY vehicle_state.vehicle_id ORDER BY vehicle_state."timestamp"), 'infinity'::timestamp with time zone) AS end_timestamp
           FROM public.vehicle_state
          ORDER BY vehicle_state.vehicle_id, vehicle_state."timestamp"
        )
 SELECT vehicles.fleet_id,
    state_info.start_timestamp AS "state timestamp",
    state_info.state,
    vehicle_location."timestamp" AS "location timestamp",
    vehicle_location.location,
    public.st_astext(vehicle_location.location) AS "human readable location"
   FROM ((public.vehicle_location vehicle_location
     RIGHT JOIN state_info ON (((vehicle_location.vehicle_id = state_info.vehicle_id) AND (vehicle_location."timestamp" >= state_info.start_timestamp) AND (vehicle_location."timestamp" < state_info.end_timestamp))))
     RIGHT JOIN public.vehicles vehicles ON ((vehicles.id = state_info.vehicle_id)));


ALTER VIEW v1_0_0.vehicle_info OWNER TO georgios;

--
-- Name: vehicle_latest_info; Type: VIEW; Schema: v1_0_0; Owner: georgios
--

CREATE VIEW v1_0_0.vehicle_latest_info AS
 SELECT DISTINCT ON (fleet_id) fleet_id,
    "state timestamp",
    state,
    "location timestamp",
    location,
    "human readable location"
   FROM v1_0_0.vehicle_info
  ORDER BY fleet_id, "state timestamp" DESC, "location timestamp" DESC;


ALTER VIEW v1_0_0.vehicle_latest_info OWNER TO georgios;

--
-- Name: vehicle_latest_location; Type: VIEW; Schema: v1_0_0; Owner: georgios
--

CREATE VIEW v1_0_0.vehicle_latest_location AS
 SELECT DISTINCT ON (vl.vehicle_id) v.fleet_id,
    vl."timestamp",
    vl.location
   FROM (public.vehicle_location vl
     JOIN public.vehicles v ON ((vl.vehicle_id = v.id)))
  ORDER BY vl.vehicle_id, vl."timestamp" DESC;


ALTER VIEW v1_0_0.vehicle_latest_location OWNER TO georgios;

--
-- Name: vehicle_latest_state; Type: VIEW; Schema: v1_0_0; Owner: georgios
--

CREATE VIEW v1_0_0.vehicle_latest_state AS
 SELECT DISTINCT ON (vs.vehicle_id) v.fleet_id,
    vs."timestamp",
    vs.state
   FROM (public.vehicle_state vs
     JOIN public.vehicles v ON ((vs.vehicle_id = v.id)))
  ORDER BY vs.vehicle_id, vs."timestamp" DESC;


ALTER VIEW v1_0_0.vehicle_latest_state OWNER TO georgios;

--
-- Name: configuration id; Type: DEFAULT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.configuration ALTER COLUMN id SET DEFAULT nextval('osm_routing_data.configuration_id_seq'::regclass);


--
-- Name: pointsofinterest pid; Type: DEFAULT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.pointsofinterest ALTER COLUMN pid SET DEFAULT nextval('osm_routing_data.pointsofinterest_pid_seq'::regclass);


--
-- Name: ways gid; Type: DEFAULT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways ALTER COLUMN gid SET DEFAULT nextval('osm_routing_data.ways_gid_seq'::regclass);


--
-- Name: ways_vertices_pgr id; Type: DEFAULT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways_vertices_pgr ALTER COLUMN id SET DEFAULT nextval('osm_routing_data.ways_vertices_pgr_id_seq'::regclass);


--
-- Name: emergencies id; Type: DEFAULT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergencies ALTER COLUMN id SET DEFAULT nextval('public.emergencies_id_seq'::regclass);


--
-- Name: emergency_state state_id; Type: DEFAULT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_state ALTER COLUMN state_id SET DEFAULT nextval('public.emergency_state_state_id_seq'::regclass);


--
-- Name: emergency_vehicles id; Type: DEFAULT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_vehicles ALTER COLUMN id SET DEFAULT nextval('public.emergency_vehicles_id_seq'::regclass);


--
-- Name: vehicle_location location_id; Type: DEFAULT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_location ALTER COLUMN location_id SET DEFAULT nextval('public.vehicle_location_location_id_seq'::regclass);


--
-- Name: vehicle_state state_id; Type: DEFAULT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_state ALTER COLUMN state_id SET DEFAULT nextval('public.vehicle_state_state_id_seq'::regclass);


--
-- Name: vehicles id; Type: DEFAULT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicles ALTER COLUMN id SET DEFAULT nextval('public.vehicles_id_seq'::regclass);


--
-- Name: osm2pgsql_properties osm2pgsql_properties_pkey; Type: CONSTRAINT; Schema: osm_raw_data; Owner: georgios
--

ALTER TABLE ONLY osm_raw_data.osm2pgsql_properties
    ADD CONSTRAINT osm2pgsql_properties_pkey PRIMARY KEY (property);


--
-- Name: configuration configuration_pkey; Type: CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.configuration
    ADD CONSTRAINT configuration_pkey PRIMARY KEY (id);


--
-- Name: configuration configuration_tag_id_key; Type: CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.configuration
    ADD CONSTRAINT configuration_tag_id_key UNIQUE (tag_id);


--
-- Name: pointsofinterest pointsofinterest_osm_id_key; Type: CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.pointsofinterest
    ADD CONSTRAINT pointsofinterest_osm_id_key UNIQUE (osm_id);


--
-- Name: pointsofinterest pointsofinterest_pkey; Type: CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.pointsofinterest
    ADD CONSTRAINT pointsofinterest_pkey PRIMARY KEY (pid);


--
-- Name: ways ways_pkey; Type: CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways
    ADD CONSTRAINT ways_pkey PRIMARY KEY (gid);


--
-- Name: ways_vertices_pgr ways_vertices_pgr_osm_id_key; Type: CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways_vertices_pgr
    ADD CONSTRAINT ways_vertices_pgr_osm_id_key UNIQUE (osm_id);


--
-- Name: ways_vertices_pgr ways_vertices_pgr_pkey; Type: CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways_vertices_pgr
    ADD CONSTRAINT ways_vertices_pgr_pkey PRIMARY KEY (id);


--
-- Name: emergencies emergencies_pkey; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergencies
    ADD CONSTRAINT emergencies_pkey PRIMARY KEY (id);


--
-- Name: emergency_state emergency_state_emergency_id_timestamp_state_key; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_state
    ADD CONSTRAINT emergency_state_emergency_id_timestamp_state_key UNIQUE (emergency_id, "timestamp", state);


--
-- Name: emergency_state emergency_state_pkey; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_state
    ADD CONSTRAINT emergency_state_pkey PRIMARY KEY (state_id);


--
-- Name: emergency_vehicles emergency_vehicles_pkey; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_vehicles
    ADD CONSTRAINT emergency_vehicles_pkey PRIMARY KEY (id);


--
-- Name: vehicle_location vehicle_location_pkey; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_location
    ADD CONSTRAINT vehicle_location_pkey PRIMARY KEY (location_id);


--
-- Name: vehicle_location vehicle_location_vehicle_id_timestamp_location_key; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_location
    ADD CONSTRAINT vehicle_location_vehicle_id_timestamp_location_key UNIQUE (vehicle_id, "timestamp", location);


--
-- Name: vehicle_state vehicle_state_pkey; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_state
    ADD CONSTRAINT vehicle_state_pkey PRIMARY KEY (state_id);


--
-- Name: vehicle_state vehicle_state_vehicle_id_timestamp_state_key; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_state
    ADD CONSTRAINT vehicle_state_vehicle_id_timestamp_state_key UNIQUE (vehicle_id, "timestamp", state);


--
-- Name: vehicles vehicles_fleet_id_key; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_fleet_id_key UNIQUE (fleet_id);


--
-- Name: vehicles vehicles_pkey; Type: CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_pkey PRIMARY KEY (id);


--
-- Name: planet_osm_line_way_idx; Type: INDEX; Schema: osm_raw_data; Owner: georgios
--

CREATE INDEX planet_osm_line_way_idx ON osm_raw_data.planet_osm_line USING gist (way) WITH (fillfactor='100');


--
-- Name: planet_osm_point_way_idx; Type: INDEX; Schema: osm_raw_data; Owner: georgios
--

CREATE INDEX planet_osm_point_way_idx ON osm_raw_data.planet_osm_point USING gist (way) WITH (fillfactor='100');


--
-- Name: planet_osm_polygon_way_idx; Type: INDEX; Schema: osm_raw_data; Owner: georgios
--

CREATE INDEX planet_osm_polygon_way_idx ON osm_raw_data.planet_osm_polygon USING gist (way) WITH (fillfactor='100');


--
-- Name: planet_osm_roads_way_idx; Type: INDEX; Schema: osm_raw_data; Owner: georgios
--

CREATE INDEX planet_osm_roads_way_idx ON osm_raw_data.planet_osm_roads USING gist (way) WITH (fillfactor='100');


--
-- Name: pointsofinterest_the_geom_idx; Type: INDEX; Schema: osm_routing_data; Owner: georgios
--

CREATE INDEX pointsofinterest_the_geom_idx ON osm_routing_data.pointsofinterest USING gist (the_geom);


--
-- Name: ways_the_geom_idx; Type: INDEX; Schema: osm_routing_data; Owner: georgios
--

CREATE INDEX ways_the_geom_idx ON osm_routing_data.ways USING gist (the_geom);


--
-- Name: ways_vertices_pgr_the_geom_idx; Type: INDEX; Schema: osm_routing_data; Owner: georgios
--

CREATE INDEX ways_vertices_pgr_the_geom_idx ON osm_routing_data.ways_vertices_pgr USING gist (the_geom);


--
-- Name: emergency_state after_conclude_emergency; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER after_conclude_emergency AFTER INSERT ON public.emergency_state FOR EACH ROW WHEN ((new.state = 'concluded'::public.emergency_state_enum)) EXECUTE FUNCTION public.fn_conclude_emergency();


--
-- Name: emergencies after_insert_emergency; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER after_insert_emergency AFTER INSERT ON public.emergencies FOR EACH ROW EXECUTE FUNCTION public.fn_emergency_initial_state();


--
-- Name: vehicles after_insert_vehicles; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER after_insert_vehicles AFTER INSERT ON public.vehicles FOR EACH ROW EXECUTE FUNCTION public.fn_vehicle_initial_state();


--
-- Name: emergency_vehicles before_set_emergency_vehicle_status; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER before_set_emergency_vehicle_status BEFORE INSERT ON public.emergency_vehicles FOR EACH ROW EXECUTE FUNCTION public.fn_emergency_vehicle_status();


--
-- Name: emergencies emergency_location_insert_check; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER emergency_location_insert_check BEFORE INSERT ON public.emergencies FOR EACH ROW EXECUTE FUNCTION public.fn_location_check();


--
-- Name: vehicle_location vehicle_location_archive; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER vehicle_location_archive AFTER DELETE ON public.vehicle_location FOR EACH ROW EXECUTE FUNCTION public.fn_vehicle_location_archive();


--
-- Name: vehicle_location vehicle_location_insert_check; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER vehicle_location_insert_check BEFORE INSERT ON public.vehicle_location FOR EACH ROW EXECUTE FUNCTION public.fn_location_check();


--
-- Name: vehicle_location vehicle_location_update_check; Type: TRIGGER; Schema: public; Owner: georgios
--

CREATE TRIGGER vehicle_location_update_check BEFORE UPDATE ON public.vehicle_location FOR EACH ROW WHEN ((old.location IS DISTINCT FROM new.location)) EXECUTE FUNCTION public.fn_location_check();


--
-- Name: ways ways_source_fkey; Type: FK CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways
    ADD CONSTRAINT ways_source_fkey FOREIGN KEY (source) REFERENCES osm_routing_data.ways_vertices_pgr(id);


--
-- Name: ways ways_source_osm_fkey; Type: FK CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways
    ADD CONSTRAINT ways_source_osm_fkey FOREIGN KEY (source_osm) REFERENCES osm_routing_data.ways_vertices_pgr(osm_id);


--
-- Name: ways ways_tag_id_fkey; Type: FK CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways
    ADD CONSTRAINT ways_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES osm_routing_data.configuration(tag_id);


--
-- Name: ways ways_target_fkey; Type: FK CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways
    ADD CONSTRAINT ways_target_fkey FOREIGN KEY (target) REFERENCES osm_routing_data.ways_vertices_pgr(id);


--
-- Name: ways ways_target_osm_fkey; Type: FK CONSTRAINT; Schema: osm_routing_data; Owner: georgios
--

ALTER TABLE ONLY osm_routing_data.ways
    ADD CONSTRAINT ways_target_osm_fkey FOREIGN KEY (target_osm) REFERENCES osm_routing_data.ways_vertices_pgr(osm_id);


--
-- Name: emergency_state emergency_state_emergency_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_state
    ADD CONSTRAINT emergency_state_emergency_id_fkey FOREIGN KEY (emergency_id) REFERENCES public.emergencies(id);


--
-- Name: emergency_vehicles emergency_vehicles_emergency_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_vehicles
    ADD CONSTRAINT emergency_vehicles_emergency_id_fkey FOREIGN KEY (emergency_id) REFERENCES public.emergencies(id);


--
-- Name: emergency_vehicles emergency_vehicles_vehicle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.emergency_vehicles
    ADD CONSTRAINT emergency_vehicles_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id);


--
-- Name: vehicle_location vehicle_location_vehicle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_location
    ADD CONSTRAINT vehicle_location_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id) ON DELETE CASCADE;


--
-- Name: vehicle_state vehicle_state_vehicle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: georgios
--

ALTER TABLE ONLY public.vehicle_state
    ADD CONSTRAINT vehicle_state_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

