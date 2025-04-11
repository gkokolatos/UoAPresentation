
DROP SCHEMA IF EXISTS osm_routing_data CASCADE;
DROP EXTENSION pgrouting;
CREATE SCHEMA IF NOT EXISTS osm_routing_data;
COMMENT ON SCHEMA
	osm_routing_data
IS 'Raw data from pgrouting import tool';
CREATE EXTENSION IF NOT EXISTS pgrouting;

SELECT 1;
\g | osm2pgrouting --file osmdata/Lesbos.osm --schema osm_routing_data --clean --dbname emergency_vehicles_lesbos --username georgios

ALTER TABLE
	osm_routing_data.ways
ALTER COLUMN
	the_geom
TYPE
	geometry(LineString,2100)
USING
	ST_Transform(the_geom,2100);

ALTER TABLE
	osm_routing_data.ways_vertices_pgr
ALTER COLUMN
	the_geom
TYPE
	geometry(Point,2100)
USING
	ST_Transform(the_geom,2100);

--
-- Get the ETA in seconds for each available vehicle in an emergency
-- Needs to fix the location to be geom and not text...
--
DROP FUNCTION IF EXISTS v1_0_0.available_eta(emergency_vid INTEGER);
CREATE OR REPLACE FUNCTION v1_0_0.available_eta(emergency_vid INTEGER)
RETURNS TABLE (
	fleet_id VARCHAR(8),
	"ETA" DOUBLE PRECISION,
	"human readable ETA" VARCHAR(8)
) AS
$$
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
$$
LANGUAGE sql;


--
-- find which timerange contains the most vehicles in patrol
--
with mydata as (select vehicle_id as id, state, next_state, timestamp, tstzrange(timestamp, lead) as range from (select vehicle_id, timestamp, lead(timestamp, 1) over next, state, lead(state, 1) over next as next_state from vehicle_state window next as (partition by vehicle_id order by timestamp asc)) where state = 'on duty'),
contained_ranges AS (
    SELECT
        tr1.id AS contained_id,
        tr1.range AS contained_range,
        COUNT(tr2.id) AS containing_count
    FROM
        mydata tr1
    JOIN
        mydata tr2
    ON
        tr2.timestamp <@ tr1.range
    GROUP BY
        tr1.id, tr1.range
)
SELECT
    contained_id,
    contained_range,
    containing_count
FROM
    contained_ranges
ORDER BY
    containing_count DESC
LIMIT 1
;


