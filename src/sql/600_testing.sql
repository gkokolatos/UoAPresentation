TRUNCATE vehicles CASCADE;
SET search_path TO v1_0_0, public;

--
-- Insert 100 vehicles and set their commissioned date a random time in the past
-- 10 days
--
-- We need two queries because the CTE version is really an UPDATE operation,
-- so the update will not have seen any rows to update. However we can perform
-- those queries within the same transaction block for the external observer to
-- see the rows at the same time.
--
-- EXPLAIN (COSTS OFF) WITH data AS (
--     SELECT
--         v1_0_0.insert_vehicle(
--             UPPER(
--                 SUBSTR(
--                     REGEXP_REPLACE(md5(i::text), '[[:digit:]]', '', 'g'), 1, 3
--                 )
--             ) || '-' || LPAD(i::text, 3, '0')) AS id,
--         CURRENT_TIMESTAMP - INTERVAL '10 days' +
--             ((FLOOR(random() * 10) *  24 * 60 * 60) || ' seconds')::INTERVAL AS timestamp
--     FROM
--         generate_series(1, 100) i
-- )
-- UPDATE
--     public.vehicle_state
-- SET
--     timestamp = data.timestamp
-- FROM
--     data
-- WHERE
--     vehicle_id = data.id
-- ;
--                        QUERY PLAN
-- ---------------------------------------------------------
--  Update on vehicle_state
--    CTE data
--      ->  Function Scan on generate_series i
--    ->  Hash Join
--          Hash Cond: (vehicle_state.vehicle_id = data.id)
--          ->  Seq Scan on vehicle_state
--          ->  Hash
--                ->  CTE Scan on data
-- (8 rows)
--

BEGIN;
SELECT
	v1_0_0.insert_vehicle(
		UPPER(
			SUBSTR(
				REGEXP_REPLACE(md5(i::text), '[[:digit:]]', '', 'g'), 1, 3
			)
		) || '-' || LPAD(i::text, 3, '0')) AS id
FROM
	generate_series(1, 100) i
;

UPDATE
	public.vehicle_state
SET
	timestamp = timestamp - INTERVAL '10 days' +
		random() * (INTERVAL '1 days' - INTERVAL '1 second') + INTERVAL '1 second'
;
COMMIT;

--
-- Assign 30% of those as decommissioned and the rest as off duty within ten
-- hours after they have been commissioned
--
WITH dsample AS (
	SELECT
		vehicle_id,
		timestamp + random() * (INTERVAL '10 hours' - INTERVAL '1 second') + INTERVAL '1 second',
		'decommissioned'::public.vehicle_state_enum
	FROM
		public.vehicle_state TABLESAMPLE BERNOULLI (30)
), sample AS (
	SELECT
		vs.vehicle_id,
		timestamp + random() * (INTERVAL '10 hours' - INTERVAL '1 second') + INTERVAL '1 second',
		'off duty'::public.vehicle_state_enum
	FROM
		public.vehicle_state vs
	LEFT JOIN
		dsample d ON vs.vehicle_id = d.vehicle_id
	WHERE
		d.vehicle_id IS NULL
	UNION ALL
	SELECT * FROM dsample
)
INSERT INTO
	public.vehicle_state (vehicle_id, timestamp, state)
SELECT
	*
FROM
	sample
;

--
-- Within the next hour, 10 random off duty vehicles went on patrol for 4 to 8 hours
--
WITH sample AS (
	SELECT
	    v.id as vehicle_id,
	    timestamp,
		random() * (INTERVAL '1 hour' - INTERVAL '1 second') + INTERVAL '1 second' AS patrol_start,
		random() * (INTERVAL '8 hours' - INTERVAL '4 hour') + INTERVAL '4 hour' AS patrol_duration
	FROM
		v1_0_0.vehicle_latest_state vl JOIN
		public.vehicles v ON
			v.fleet_id = vl.fleet_id
	WHERE
	    state = 'off duty'
	ORDER BY
		random()
	LIMIT
		10
), on_duty AS (
	INSERT INTO
		public.vehicle_state (vehicle_id, timestamp, state)
	SELECT
		vehicle_id,
		timestamp + patrol_start,
		'on duty'
	FROM
	sample
	RETURNING
		*
), off_duty AS (
	INSERT INTO
		public.vehicle_state (vehicle_id, timestamp, state)
	SELECT
		vehicle_id,
		timestamp + patrol_start + patrol_duration,
		'off duty'
	FROM
		sample
	RETURNING
		*
)
SELECT * FROM on_duty
UNION ALL
SELECT * FROM off_duty;

WITH RECURSIVE patrol_vehicles AS (
	-- Step 1: Select the vehicles that went on patrol and remember when they
	-- started and how many minutes it lasted
	SELECT
		vehicle_id,
		timestamp AS ticker_start,
		FLOOR(EXTRACT(epoch from next_timestamp - timestamp) / 60) AS tick_count,
		ROW_NUMBER() OVER () AS rn                             -- Give an attribute to be able to join with the roads
	FROM (
		SELECT
			vehicle_id,
			timestamp,
			state,
			LEAD(timestamp, 1) OVER state_window AS next_timestamp,
			LEAD(state, 1)     OVER state_window AS next_state
		FROM
			vehicle_state
		WINDOW
			state_window AS (PARTITION BY vehicle_id ORDER BY timestamp ASC)
	) foo
	WHERE
		state = 'on duty' AND
		next_state = 'off duty'
), road_selection AS (
	-- Step 2: Select an equal amount of random long-ish roads
	SELECT
		*,
		ROW_NUMBER() OVER () AS rn
	FROM (
		SELECT
			osm_id,
			way AS road, 										-- The geometry
			ST_LineInterpolatePoint(way, 0.0) AS start_point,	-- The starting point of the road (0% along the road),
			ST_LineInterpolatePoint(way, 1.0) AS end_point		-- The final point of the road (100% along the road),
		FROM
			osm_raw_data.planet_osm_roads
		WHERE
			highway IN ('primary', 'secondary', 'tertiary', 'residential') AND
			ST_Length(way) > 200.0
		ORDER BY
			random()
		LIMIT
			(SELECT count(*) FROM patrol_vehicles)
	)
), vehicle_roads AS (
	-- Step 3: Assign a vehicle to a road
	SELECT
		*
	FROM
		road_selection JOIN
		patrol_vehicles ON
			patrol_vehicles.rn = road_selection.rn
), tracker_ticks AS (
	-- Step 4: Recursively calculate the vehicle's travel along the road
	-- assuming that the vehicle moves about 100 meters between ticks, unless
	-- close to a junction
	SELECT
		vehicle_id,
		ticker_start,
		tick_count,
		0 AS nticks,                                           -- Starting at step 0
		0.0::double precision AS fraction,                     -- Starting at 0% progress along the road
		road,
		start_point,
		end_point
	FROM
		vehicle_roads
	UNION ALL
	SELECT
		tt.vehicle_id,
		ticker_start,
		tick_count,
		tt.nticks + 1,                                         -- Increment the sequence step
		CASE
			WHEN tt.fraction >= 0.95 THEN 0.0                  -- If the vehicle is near the end, reset progress to 0
			WHEN tt.fraction + (100.0 / ST_Length(tt.road)) >= 0.95 THEN 0.96
			ELSE tt.fraction + (100.0 / ST_Length(tt.road))    -- Otherwise, increment progress along the road
		END,
		CASE
			WHEN tt.fraction >= 0.95 THEN nr.road              -- Switch road when near the end
			ELSE tt.road
		END,
		CASE
			WHEN tt.fraction >= 0.95 THEN ST_LineInterpolatePoint(nr.road, 0.0)  -- Set new start point for the next road
			ELSE tt.start_point
		END,
		CASE
			WHEN tt.fraction >= 0.95 THEN ST_LineInterpolatePoint(nr.road, 1.0)  -- Set new end point for the next road
			ELSE tt.end_point
		END
	FROM
		tracker_ticks tt
	LEFT JOIN LATERAL (
		-- Select a road close to the end as the next road to move along to
		SELECT
			r.way AS road
		FROM
			osm_raw_data.planet_osm_roads r
		WHERE
			ST_DWithin(ST_LineInterpolatePoint(r.way, 0.0), tt.end_point, 0.0005) AND
			highway IN ('primary', 'secondary', 'tertiary', 'residential')
		ORDER BY
			random()                                           -- Do not always turn on the same direction
		LIMIT
			1
	) nr ON
		tt.fraction >= 0.95                                    -- Switch road if near the end of the current road
	WHERE
		tt.nticks <  tt.tick_count                             -- Stop tracking at the end of patrol
), tracker_points AS (
	-- Step 5: Construct the location + timestamp information
	SELECT
		vehicle_id,
		ticker_start + (nticks || ' minutes')::INTERVAL AS timestamp,
		CASE
			WHEN random() < 0.2 THEN
				-- 20% chance for some random pause (using the previous location)
				LAG(ST_LineInterpolatePoint(road, fraction)) OVER (PARTITION BY vehicle_id ORDER BY nticks)
			ELSE
				-- Otherwise, calculate current position along the road
				-- It will appear as the vehicle was lunging forward at times
				ST_LineInterpolatePoint(road, fraction)
		END AS location
	FROM
		tracker_ticks
)
-- Step 6: Populate the vehicle_location table
INSERT INTO
	vehicle_location (vehicle_id, timestamp, location)
SELECT
	vehicle_id,
	timestamp,
	location
FROM
	tracker_points
WHERE
	location IS NOT NULL;

