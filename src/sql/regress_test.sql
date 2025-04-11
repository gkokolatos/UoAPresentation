--------------------------------------------------------------------------------
--
-- Vehicles section
--
--------------------------------------------------------------------------------

--
-- Validity of fleet_id
--

-- Should fail, lowercase
INSERT INTO vehicles (fleet_id) VALUES ('aaa-001');

-- Should fail, length
INSERT INTO vehicles (fleet_id) VALUES ('AAA-001 ');

--Should fail, wrong pattern
INSERT INTO vehicles (fleet_id) VALUES ('AAAA-01');
INSERT INTO vehicles (fleet_id) VALUES ('AAA-01A');
INSERT INTO vehicles (fleet_id) VALUES (' AA-010');
INSERT INTO vehicles (fleet_id) VALUES ('AAA+001');

-- Should succeed
INSERT INTO vehicles (fleet_id) VALUES ('AAA-000');

-- Should fail with unique violation
INSERT INTO vehicles (fleet_id) VALUES ('AAA-000');

--
-- Validity of state
--

-- Successful insert into vehicles must generate an entry in states
SELECT
	v.fleet_id,
	vs.state
FROM
	vehicle_state vs JOIN
	vehicles v ON (
		v.id = vs.vehicle_id
	)
WHERE
	v.fleet_id = 'AAA-000'
;

-- Should fail for invalid state
INSERT INTO
	vehicle_state (vehicle_id, state)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	'invalid'
);

-- Should fail for unique violation
INSERT INTO
	vehicle_state (vehicle_id, timestamp, state)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	(SELECT timestamp FROM vehicle_state WHERE state = 'commissioned'),
	'commissioned'
);

--
-- Validity of location
--

-- Should fail, not in Lesvos
INSERT INTO
	vehicle_location (vehicle_id, location)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	ST_Transform(ST_Point(39.177156, 26.373316, 4326), 2100)
);

-- Should succeed
INSERT INTO
	vehicle_location (vehicle_id, location)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	ST_Transform(ST_Point(26.373316, 39.177156, 4326), 2100)
);

--
-- All data should be present
--
SELECT
	v.fleet_id,
	vs.state,
	ST_AsText(ST_Transform(vl.location, 4326)) AS "location WGS84"
FROM
	vehicles v JOIN
	vehicle_state vs ON
		v.id = vs.vehicle_id JOIN
	vehicle_location vl ON
		v.id = vl.vehicle_id
;

--
-- Delete from vehicle_location should archive
--
DELETE FROM
	vehicle_location vl
USING
	vehicles v
WHERE
	v.fleet_id = 'AAA-000' AND
    vl.vehicle_id = v.id
;

SELECT
	ST_AsText(ST_Transform(location, 4326)) AS "location WGS84"
FROM
	archive.vehicle_location
;
	
--------------------------------------------------------------------------------
--
-- Emergency section
--
--------------------------------------------------------------------------------

--
-- Validity of location
--

-- Should fail, not in Lesvos
INSERT INTO
	emergencies (location, description)
VALUES (
	ST_Transform(ST_Point(39.177156, 26.373316, 4326), 2100),
	'Διαβολόρεμα πλημμύρα'
);

-- Should succeed
INSERT INTO
	emergencies (location, description)
VALUES (
	ST_Transform(ST_Point(26.373316, 39.177156, 4326), 2100),
	'Διαβολόρεμα πλημμύρα'
);

-- Successful insert into emergencies must generate an entry in states
SELECT
	state = 'declared' as success
FROM
	emergency_state
WHERE
	emergency_id = (
		SELECT id FROM emergencies WHERE description = 'Διαβολόρεμα πλημμύρα'
	)
;

--
-- Validity of state
--

-- Invalid state
INSERT INTO
	emergency_state (emergency_id, state)
VALUES (
	(SELECT id FROM emergencies WHERE description = 'Διαβολόρεμα πλημμύρα'),
	'invalid'
);

--
-- Validity of vehicle state
--

-- Should fail due to vehicle's state
INSERT INTO
	emergency_vehicles (emergency_id, vehicle_id, status)
VALUES (
	(SELECT id FROM emergencies WHERE description = 'Διαβολόρεμα πλημμύρα'),
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	'attached'
);

-- Insert new state for the vehicle
INSERT INTO
	vehicle_state (vehicle_id, state)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	'on duty'
);

-- Should succeed
INSERT INTO
	emergency_vehicles (emergency_id, vehicle_id, status)
VALUES (
	(SELECT id FROM emergencies WHERE description = 'Διαβολόρεμα πλημμύρα'),
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	'attached'
);

-- Vehicle state must have changed
SELECT
	state = 'assigned'
FROM
	vehicle_state
WHERE
	vehicle_id = (SELECT id FROM vehicles WHERE fleet_id = 'AAA-000')
ORDER BY
	timestamp DESC
LIMIT 1
;

-- Detach vehicle
INSERT INTO
	emergency_vehicles (emergency_id, vehicle_id, status)
VALUES (
	(SELECT id FROM emergencies WHERE description = 'Διαβολόρεμα πλημμύρα'),
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	'detached'
);

-- Vehicle state must have changed
SELECT
	state = 'on duty'
FROM
	vehicle_state
WHERE
	vehicle_id = (SELECT id FROM vehicles WHERE fleet_id = 'AAA-000')
ORDER BY
	timestamp DESC
LIMIT 1
;

-- Reattach it to check state after conclussion
INSERT INTO
	emergency_vehicles (emergency_id, vehicle_id, status)
VALUES (
	(SELECT id FROM emergencies WHERE description = 'Διαβολόρεμα πλημμύρα'),
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	'attached'
);

-- Conclude the emergency
INSERT INTO
	emergency_state (emergency_id, state)
SELECT
	id,
	'concluded'
FROM
	emergencies
WHERE
	description = 'Διαβολόρεμα πλημμύρα'
;
