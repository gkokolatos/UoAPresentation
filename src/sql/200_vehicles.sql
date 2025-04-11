--
-- Create the base relation
--
CREATE TABLE vehicles (
	id serial PRIMARY KEY,
	fleet_id varchar(8) UNIQUE NOT NULL,
	CONSTRAINT
		valid_fleet_identifier
	CHECK (
		fleet_id ~ '^[A-Z]{3}-[0-9]{3}$'
	)
);
COMMENT ON TABLE
	vehicles
IS
	'Base relation for vehicles';

--
-- Create the enum type for the states
--
CREATE TYPE
	vehicle_state_enum 
AS ENUM (
	'commissioned',
	'decommissioned',
	'on duty',
	'off duty',
	'assigned'
);
COMMENT ON TYPE
	vehicle_state_enum
IS
	'This enumerated type represents possible states \
	 of a vehicle in the fleet'
;

--
-- Create the state table
--
CREATE TABLE vehicle_state (
	state_id serial PRIMARY KEY,
	vehicle_id integer REFERENCES vehicles (id) ON DELETE CASCADE NOT NULL,
	timestamp timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
	state vehicle_state_enum NOT NULL,
	UNIQUE (vehicle_id, timestamp, state)
);
COMMENT ON TABLE
	vehicle_state
IS
	'A log for the state of each vehicle at a given time'
;

--
-- Create the trigger function
--
CREATE OR REPLACE FUNCTION fn_vehicle_initial_state()
RETURNS TRIGGER AS
$body$
BEGIN
	INSERT INTO
		vehicle_state (vehicle_id, state)
	VALUES
		(NEW.id, 'commissioned');
	RETURN NEW;
END;
$body$
LANGUAGE plpgsql;

CREATE TRIGGER
	after_insert_vehicles
AFTER INSERT ON
	vehicles
FOR EACH ROW EXECUTE FUNCTION 
	fn_vehicle_initial_state();

--
-- The location log table
--
CREATE TABLE vehicle_location (
	location_id bigserial PRIMARY KEY,
	vehicle_id integer REFERENCES vehicles (id) ON DELETE CASCADE NOT NULL,
	timestamp timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
	location geometry(POINT, 2100) NOT NULL, -- The Hellenic SRID, EGSA87
	UNIQUE (vehicle_id, timestamp, location)
);
COMMENT ON TABLE
	vehicle_location
IS
	'A log for the location of each vehicle at a given time'
;

CREATE OR REPLACE FUNCTION fn_location_check ()
RETURNS TRIGGER AS
$body$
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
$body$
LANGUAGE plpgsql;

CREATE TRIGGER
	vehicle_location_insert_check
BEFORE INSERT ON
	vehicle_location
FOR EACH ROW EXECUTE FUNCTION
	fn_location_check()
;

CREATE TRIGGER
	vehicle_location_update_check
BEFORE UPDATE ON
	vehicle_location
FOR EACH ROW
WHEN (OLD.location IS DISTINCT FROM NEW.location)
EXECUTE FUNCTION
	fn_location_check()
;

CREATE SCHEMA IF NOT EXISTS archive;

CREATE TABLE archive.vehicle_location (
	LIKE public.vehicle_location
);
COMMENT ON TABLE
	archive.vehicle_location
IS
	'Historical entries of vehicle_location table'
;

CREATE OR REPLACE FUNCTION fn_vehicle_location_archive ()
RETURNS TRIGGER AS
$body$
BEGIN
	INSERT INTO
		archive.vehicle_location
	VALUES
		(OLD.*);
	RETURN OLD;
END;
$body$
LANGUAGE plpgsql;

CREATE TRIGGER
	vehicle_location_archive
AFTER DELETE ON
	vehicle_location
FOR EACH ROW EXECUTE FUNCTION
	fn_vehicle_location_archive()
;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT
	cron.schedule(
		'5 0 * * *',
		$body$
			DELETE FROM
				public.vehicle_location
			WHERE
				timestamp < NOW() - INTERVAL '1 WEEK'
		$body$
	);

;
