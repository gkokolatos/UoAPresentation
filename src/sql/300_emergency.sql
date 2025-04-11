--
-- Create the base relation
--
CREATE TABLE emergencies (
	id serial PRIMARY KEY,
	location geometry(POINT, 2100) NOT NULL, -- The Hellenic SRID, EGSA87
	description text NOT NULL
);
COMMENT ON TABLE
	emergencies
IS
	'Base relation for emergencies';

CREATE TRIGGER
	emergency_location_insert_check
BEFORE INSERT ON
	emergencies
FOR EACH ROW EXECUTE FUNCTION
	fn_location_check()
;

CREATE TYPE
	emergency_state_enum 
AS ENUM (
	'declared',
	'active',
	'concluded'
);
COMMENT ON TYPE
	emergency_state_enum
IS
	'This enumerated type represents possible states \
	 of an emergency'
;

CREATE TABLE emergency_state (
	state_id serial PRIMARY KEY,
	emergency_id integer REFERENCES emergencies (id) NOT NULL,
	timestamp timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
	state emergency_state_enum NOT NULL,
	UNIQUE (emergency_id, timestamp, state)
);
COMMENT ON TABLE
	emergency_state
IS
	'A log for the state of each emergency at a given time'
;

--
-- Create the trigger function
--
CREATE OR REPLACE FUNCTION fn_emergency_initial_state()
RETURNS TRIGGER AS
$body$
BEGIN
	INSERT INTO
		emergency_state (emergency_id, state)
	VALUES
		(NEW.id, 'declared');
	RETURN NEW;
END;
$body$
LANGUAGE plpgsql;

CREATE TRIGGER
	after_insert_emergency
AFTER INSERT ON
	emergencies
FOR EACH ROW EXECUTE FUNCTION 
	fn_emergency_initial_state();

CREATE TYPE
	emergency_vehicles_enum 
AS ENUM (
	'attached',
	'detached'
);
COMMENT ON TYPE
	emergency_vehicles_enum
IS
	'This enumerated type represents possible states \
	 of a vehicle taking part in an emergency'
;

CREATE TABLE emergency_vehicles (
	id serial PRIMARY KEY,
	emergency_id integer REFERENCES emergencies (id) NOT NULL,
	vehicle_id integer REFERENCES vehicles (id) NOT NULL,
	timestamp timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
	status emergency_vehicles_enum NOT NULL
);
COMMENT ON TABLE
	emergency_vehicles
IS
	'A log for the vehicles assigned on an emergency at a given time'
;

CREATE OR REPLACE FUNCTION fn_emergency_vehicle_status()
RETURNS TRIGGER AS
$body$
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
$body$
LANGUAGE plpgsql;

CREATE TRIGGER
	before_set_emergency_vehicle_status
BEFORE INSERT ON
	emergency_vehicles
FOR EACH ROW EXECUTE FUNCTION 
	fn_emergency_vehicle_status();

CREATE OR REPLACE FUNCTION fn_conclude_emergency()
RETURNS TRIGGER AS
$body$
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
$body$
LANGUAGE plpgsql;

CREATE TRIGGER
	after_conclude_emergency
AFTER INSERT ON
	emergency_state
FOR EACH ROW 
WHEN (NEW.state = 'concluded')
EXECUTE FUNCTION
	fn_conclude_emergency();

-- insert into emergencies (location) values (ST_Transform(ST_Point(26.373316, 39.177156, 4326), 2100));

--EXPLAIN (COSTS OFF) SELECT
--        vs.*
--FROM                       
--        vehicle_state AS vs            
--INNER JOIN (
--        SELECT               
--                vehicle_id,
--                max(state_id) as state_id
--        FROM
--                vehicle_state
--        GROUP BY                 
--                vehicle_id
--) AS l ON (                 
--        l.vehicle_id = vs.vehicle_id AND
--        l.state_id = vs.state_id
--)                                 
--ORDER BY                                
--        vs.vehicle_id,
--        vs.state_id DESC
--;
--                                                    QUERY PLAN                                                     
---------------------------------------------------------------------------------------------------------------------
-- Sort
--   Sort Key: vs.vehicle_id, vs.state_id DESC
--   ->  Hash Join
--         Hash Cond: ((vs.vehicle_id = vehicle_state.vehicle_id) AND (vs.state_id = (max(vehicle_state.state_id))))
--         ->  Seq Scan on vehicle_state vs
--         ->  Hash
--               ->  HashAggregate
--                     Group Key: vehicle_state.vehicle_id
--                     ->  Seq Scan on vehicle_state
--(9 rows)


--EXPLAIN (COSTS OFF) WITH foo AS (
--        SELECT
--                vehicle_id,
--                MAX(state_id) as state_id
--        FROM
--                vehicle_state
--        GROUP BY
--                vehicle_id
--)
--SELECT
--        vs.*
--FROM
--        vehicle_state AS vs,
--        foo
--WHERE
--        vs.state_id = foo.state_id
--;
--                         QUERY PLAN
--------------------------------------------------------------
-- Hash Join
--   Hash Cond: ((max(vehicle_state.state_id)) = vs.state_id)
--   ->  HashAggregate
--         Group Key: vehicle_state.vehicle_id
--         ->  Seq Scan on vehicle_state
--   ->  Hash
--         ->  Seq Scan on vehicle_state vs
--(7 rows)

-- EXPLAIN (COSTS OFF) SELECT
--         vs.*
-- FROM
--         vehicle_state AS vs
-- INNER JOIN LATERAL (
--         SELECT
--                 state_id,
--                 state
--         FROM
--                 vehicle_state AS ivs
--         WHERE
--                 ivs.vehicle_id = vs.vehicle_id
--         ORDER BY
--                 ivs.state_id DESC
--         LIMIT
--                 1
-- ) AS l ON (
--         l.state_id = vs.state_id
-- )
-- ORDER BY
--         vs.vehicle_id,
--         vs.state_id DESC
-- ;
--                                           QUERY PLAN
-- -----------------------------------------------------------------------------------------------
--  Incremental Sort
--    Sort Key: vs.vehicle_id, vs.state_id DESC
--    Presorted Key: vs.vehicle_id
--    ->  Nested Loop
--          ->  Index Scan using vehicle_state_vehicle_id_timestamp_state_key on vehicle_state vs
--          ->  Subquery Scan on l
--                Filter: (vs.state_id = l.state_id)
--                ->  Limit
--                      ->  Index Scan Backward using vehicle_state_pkey on vehicle_state ivs
--                            Filter: (vehicle_id = vs.vehicle_id)
-- (10 rows)




