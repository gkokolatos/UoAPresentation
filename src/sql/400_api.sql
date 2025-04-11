DROP SCHEMA IF EXISTS v1_0_0 CASCADE;
CREATE SCHEMA v1_0_0;
COMMENT ON SCHEMA
    v1_0_0
IS 'Version 1.0.0 of the application interface';

SET search_path TO v1_0_0, public;

CREATE OR REPLACE FUNCTION insert_vehicle(
    in_fleet_id text
)
RETURNS public.vehicles.id%TYPE
AS
$$
    INSERT INTO
        public.vehicles (fleet_id)
    VALUES (
        in_fleet_id
    )
    RETURNING
        id;
$$
LANGUAGE sql;

CREATE OR REPLACE FUNCTION delete_vehicle(
    in_fleet_id text
)
RETURNS public.vehicles.id%TYPE
AS
$$
   DELETE FROM 
        public.vehicles 
	WHERE
        in_fleet_id = in_fleet_id
    RETURNING
        id;
$$
LANGUAGE sql;

--
-- This will NOT return null on non existing fleet_id
-- because it is a single row insert
--
CREATE OR REPLACE FUNCTION assign_vehicle_state(
    in_fleet_id text,
    in_state public.vehicle_state.state%TYPE
)
RETURNS public.vehicle_state.state_id%TYPE
AS
$$
	INSERT INTO
		public.vehicle_state (vehicle_id, state)
	VALUES (
		(SELECT id FROM public.vehicles WHERE fleet_id = in_fleet_id),
		in_state
	)
	RETURNING
		state_id;
$$
LANGUAGE sql;

--
-- This will return null on non existing fleet_id
-- because it is a bulk insert
--
CREATE OR REPLACE FUNCTION v1_0_0.assign_vehicle_location(
    in_fleet_id text,
	in_location geometry(Point,2100)
)
RETURNS public.vehicle_location.location_id%TYPE
AS
$$
	INSERT INTO
		public.vehicle_location (vehicle_id, location)
	SELECT
		id,
		in_location
	FROM
		public.vehicles
	WHERE
		fleet_id = in_fleet_id
	RETURNING
		location_id;
$$
LANGUAGE sql;

--
-- This will return null on non existing fleet_id
--
CREATE OR REPLACE FUNCTION v1_0_0.assign_vehicle_location(
    in_fleet_id text,
	in_location geometry(Point,4326)
)
RETURNS public.vehicle_location.location_id%TYPE
AS
$$
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
$$
LANGUAGE sql;

--
-- Find the latest state of all vehicles
--
-- SELECT DISTINCT ON ( expression [, ...] ) keeps only the first row of each set of rows where the given expressions evaluate to equal. The DISTINCT ON expressions are interpreted using the same rules as for ORDER BY (see above). Note that the “first row” of each set is unpredictable unless ORDER BY is used to ensure that the desired row appears first. For example:
--
CREATE OR REPLACE VIEW vehicle_latest_state AS
 	SELECT
		DISTINCT ON (vs.vehicle_id)
		v.fleet_id,
		vs.timestamp,
		vs.state
	FROM
		public.vehicle_state vs JOIN
		public.vehicles v ON (
			vs.vehicle_id = v.id
		)
	ORDER BY
		vehicle_id,
		timestamp DESC;

--
-- Find the latest location of all vehicles
--
CREATE OR REPLACE VIEW vehicle_latest_location AS
 	SELECT
		DISTINCT ON (vl.vehicle_id)
		v.fleet_id,
		vl.timestamp,
		vl.location
	FROM
		public.vehicle_location vl JOIN
		public.vehicles v ON (
			vl.vehicle_id = v.id
		)
	ORDER BY
		vehicle_id,
		timestamp DESC;

--
-- Vehicle info, this is the view that the app will be mostly interacting with
--
CREATE OR REPLACE VIEW vehicle_info AS
	WITH state_info AS (
		SELECT
			vehicle_id,
			state,
			timestamp AS start_timestamp,
			COALESCE(
				LEAD(timestamp, 1) OVER (PARTITION BY vehicle_id ORDER BY timestamp ASC),
				'infinity'::timestamptz
			) AS end_timestamp
		FROM
			public.vehicle_state
		ORDER BY
			vehicle_id ASC,
			timestamp ASC
	)
	SELECT
		vehicles.fleet_id,
		state_info.start_timestamp AS "state timestamp",
		state_info.state,
		vehicle_location.timestamp AS "location timestamp",
		location,
		ST_AsText(location) AS "human readable location"
	FROM
		public.vehicle_location AS vehicle_location
	RIGHT JOIN
		state_info ON (
				vehicle_location.vehicle_id = state_info.vehicle_id AND
				vehicle_location.timestamp >= state_info.start_timestamp AND
				vehicle_location.timestamp < state_info.end_timestamp
		)
	RIGHT JOIN
		public.vehicles AS vehicles ON (
			vehicles.id = state_info.vehicle_id
		);


--
-- Combining the above, vehicle's latest info
--
CREATE OR REPLACE VIEW vehicle_latest_info AS
	SELECT
		DISTINCT ON (fleet_id)
		*
	 FROM
		v1_0_0.vehicle_info
	ORDER BY
		fleet_id,
		"state timestamp" DESC,
		"location timestamp" DESC
