---
title: Schema Testing
author: Georgios Kokolatos
date: 11th of April, 2025

custom_chapters:
  - {href: chapter1.html, label: Introduction}
  - {href: chapter2.html, label: Setting up}
  - {href: chapter3.html, label: Schemata}
  - {href: chapter4.html, label: Import OSM Data}
  - {href: chapter5.html, label: Vehicle log}
  - {href: chapter6.html, label: Emergencies}
  - {href: chapter7.html, label: Schema Testing}
  - {href: chapter8.html, label: Application Interface}
  - {href: chapter9.html, label: Generating vehicle data}
  - {href: chapter10.html, label: Routing}

prev_chapter:
  href: chapter6.html
  label: Emergencies
  title: Emergencies

next_chapter:
  href: chapter8.html
  label: Application Interface
  title: Application Interface

custom_toc:
  - {href: schema-testing, label: 7. Schema testing}
  - {href: a-rudimentary-example, label: 7.1 A rudimentary example}
---

# 7. Schema testing

The schema definition provides a set of guarantees and functionality. As a
result, we hold several expectations. In order to be reasonably certain that
our expectations hold ***and*** that we do not violate those expectations when
we alter the schema, we need to be contentiously testing them. A simple
implementation of *regress testing* usually suffices. Commonly, it forms part
of a Continuous Integration / Continuous Delivery environment.

However, a very simple rule such as:

```bash
$ psql <connection string> \
    --file <input.sql> \
    --echo-queries > generated.out 2>&1 && \
    diff generated.out <expected.out>
```

will suffice. Of course, date and time differences, floating point, random
generators etc, will require a more advanced implementation. One highly
recommended one, at least as a starting point, can be found in Dimitri's
[github](https://github.com/dimitri/regresql).


## 7.1 Our schema

```
                         ┌────────────────────┐
                         │     vehicles       │
                         │────────────────────│
                         │ id (PK)            │
                         │ fleet_id           │
                         └────────┬───────────┘
                                  │ 
        ┌─────────────────────────┴─────────────────────────┐
        ▼                          ▼                        ▼
┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
│ vehicle_location   │   │ vehicle_state      │   │ emergency_vehicles │
│────────────────────│   │────────────────────│   │────────────────────│
│ location_id (PK)   │   │ state_id (PK)      │   │ id (PK)            │
│ timestamp          │   │ timestamp          │   │ vehicle_id (FK) ◄──┘
│ vehicle_id (FK)  ◄─┘   │ vehicle_id (FK) ◄──┘   │ emergency_id (FK) ◄┐
│ location           │   │ state (enum)       │   │ timestamp          │
└────────────────────┘   └────────────────────┘   │ status (enum)      │
                                                  └────────────────────┘
                                                           ▲
                                                           │
                                                           │
                                             ┌──────────────────────────┐
                                             │     emergencies          │
                                             │──────────────────────────│
                                             │ id (PK)                  │
                                             │ location (geom)          │
                                             │ description              │
                                             └────────┬─────────────────┘
                                                      │ 
                                                      ▼
                                        ┌──────────────────────────────┐
                                        │     emergency_state          │
                                        │──────────────────────────────│
                                        │ state_id (PK)                │
                                        │ emergency_id (FK) ◄──────────┘
                                        │ timestamp                    │
                                        │ state (enum)                 │
                                        └──────────────────────────────┘

```

## 7.2 A rudimentary example

A simple input file for regress testing the vehicle related relations may look
like this:

```sql
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
	
```

Which should generate an output like this:

```sql
psql:src/sql/regress_test.sql:12: ERROR:  new row for relation "vehicles" violates check constraint "valid_fleet_identifier"
DETAIL:  Failing row contains (1, aaa-001).
psql:src/sql/regress_test.sql:12: STATEMENT:  INSERT INTO vehicles (fleet_id) VALUES ('aaa-001');
psql:src/sql/regress_test.sql:15: ERROR:  new row for relation "vehicles" violates check constraint "valid_fleet_identifier"
DETAIL:  Failing row contains (2, AAA-001 ).
psql:src/sql/regress_test.sql:15: STATEMENT:  INSERT INTO vehicles (fleet_id) VALUES ('AAA-001 ');
psql:src/sql/regress_test.sql:18: ERROR:  new row for relation "vehicles" violates check constraint "valid_fleet_identifier"
DETAIL:  Failing row contains (3, AAAA-01).
psql:src/sql/regress_test.sql:18: STATEMENT:  INSERT INTO vehicles (fleet_id) VALUES ('AAAA-01');
psql:src/sql/regress_test.sql:19: ERROR:  new row for relation "vehicles" violates check constraint "valid_fleet_identifier"
DETAIL:  Failing row contains (4, AAA-01A).
psql:src/sql/regress_test.sql:19: STATEMENT:  INSERT INTO vehicles (fleet_id) VALUES ('AAA-01A');
psql:src/sql/regress_test.sql:20: ERROR:  new row for relation "vehicles" violates check constraint "valid_fleet_identifier"
DETAIL:  Failing row contains (5,  AA-010).
psql:src/sql/regress_test.sql:20: STATEMENT:  INSERT INTO vehicles (fleet_id) VALUES (' AA-010');
psql:src/sql/regress_test.sql:21: ERROR:  new row for relation "vehicles" violates check constraint "valid_fleet_identifier"
DETAIL:  Failing row contains (6, AAA+001).
psql:src/sql/regress_test.sql:21: STATEMENT:  INSERT INTO vehicles (fleet_id) VALUES ('AAA+001');
INSERT 0 1
psql:src/sql/regress_test.sql:27: ERROR:  duplicate key value violates unique constraint "vehicles_fleet_id_key"
DETAIL:  Key (fleet_id)=(AAA-000) already exists.
psql:src/sql/regress_test.sql:27: STATEMENT:  INSERT INTO vehicles (fleet_id) VALUES ('AAA-000');
 fleet_id |    state     
----------+--------------
 AAA-000  | commissioned
(1 row)

psql:src/sql/regress_test.sql:52: ERROR:  invalid input value for enum vehicle_state_enum: "invalid"
LINE 5:  'invalid'
         ^
psql:src/sql/regress_test.sql:52: STATEMENT:  INSERT INTO
	vehicle_state (vehicle_id, state)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	'invalid'
);
psql:src/sql/regress_test.sql:61: ERROR:  duplicate key value violates unique constraint "vehicle_state_vehicle_id_timestamp_state_key"
DETAIL:  Key (vehicle_id, "timestamp", state)=(7, 2025-04-23 19:39:11.177991+02, commissioned) already exists.
psql:src/sql/regress_test.sql:61: STATEMENT:  INSERT INTO
	vehicle_state (vehicle_id, timestamp, state)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	(SELECT timestamp FROM vehicle_state WHERE state = 'commissioned'),
	'commissioned'
);
psql:src/sql/regress_test.sql:73: ERROR:  Location (POINT(2024724.3888534778 3007855.7431474472)) out of bounds
HINT:  Please check that the location is within Lesvos
CONTEXT:  PL/pgSQL function fn_location_check() line 14 at RAISE
psql:src/sql/regress_test.sql:73: STATEMENT:  INSERT INTO
	vehicle_location (vehicle_id, location)
VALUES (
	(SELECT id FROM vehicles WHERE fleet_id = 'AAA-000'),
	ST_Transform(ST_Point(39.177156, 26.373316, 4326), 2100)
);
INSERT 0 1
 fleet_id |    state     |               location WGS84                
----------+--------------+---------------------------------------------
 AAA-000  | commissioned | POINT(26.373315987937836 39.17715598285773)
(1 row)

DELETE 1
               location WGS84                
---------------------------------------------
 POINT(26.373315987937836 39.17715598285773)
(1 row)

```
