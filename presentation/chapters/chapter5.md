---
title: Vehicle log
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
  href: chapter4.html
  label: Import OSM Data
  title: Import OSM Data

next_chapter:
  href: chapter6.html
  label: Emergencies
  title: Emergencies

custom_toc:
  - {href: vehicle-log, label: 5 Vehicle log}
  - {href: the-base-relation, label: 5.1 The base relation}
  - {href: possible-states, label: 5.2 Possible states}
  - {href: the-initial-state-problem, label: 5.3 The initial state problem}
  - {href: vehicle-location-log, label: 5.4 Vehicle location log}
  - {href: vehicle-location-validator, label: 5.5 Vehicle location validator}
  - {href: vehicle-location-archiver, label: 5.6 Vehicle location archiver}
  - {href: reality-bites, label: 5.7 Reality bites}

---

# 5 Vehicle log

**As a user I want to**:

* be able to add new and list existing vehicles in the fleet
* quickly know their availability
* quickly know their current location

**So that**:

* I can have an overview of the fleet at any moment

**Because**:

* I need to be able to respond to emergencies efficiently

### Problem definitions 

* A vehicle is defined by its ***unique alphanumeric identifier***, having a
  pattern of three uppercase letters followed by a dash followed by three digits
* A vehicle ***must*** have ***one and only one*** of the following states on
  any given time:
  * commissioned           - *the initial state*
  * decommissioned         - *eg: undergoing service*
  * on duty                - *manned and ready to serve*
  * off duty               - *unmanned*
  * assigned               - *currently on an emergency*
* We do not expect many vehicles, in the ballpark of tens
* We do expect a handful of state changes per day
* Each vehicle is equipped with a tracker which pings in predefined intervals its
  location.
* Each vehicle must be in Lesbos mainland

## 5.1 The base relation

Already from the problem definition becomes apparent that we can not express it
all in a single relation. The base relation ***should*** contain:

* The identifier for the vehicle

<details>
<summary>Implementation</summary>
```sql
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
```
</details>

## 5.2 Possible states

It is not uncommon free text, or integer values to be used for such state
representations. Those are esoteric to the code and prone to errors as they lack
validity guarantees. Enumerated types solve this problem elegantly and
efficiently.

<details>
<summary>Enumerations</summary>

```sql
CREATE TYPE
    vehicle_state_enum 
AS ENUM (
    'commissioned',
    'decommissioned',
    'on duty',
    'off duty',
    'assigned'
);
COMMENT ON TYPE vehicle_state_enum IS
'This enumerated type represents possible states of a vehicle in the fleet:
 - commissioned: The vehicle is active and ready for assignment.
 - decommissioned: The vehicle is currently not in active use.
 - on duty: The vehicle is currently active in the field.
 - off duty: The vehicle is idle.
 - assigned: The vehicle has been assigned to an emergency.
';
```
</details>

Now we can use the newly created type in the table. The relation ***should***
contain:

* The vehicle identifier
* The date and time of the state change
* The state

***Note***: Since we do not expect this table to grow too much, about 50
vehicles undergoing 20 state changes a day will result in a table size of ~5GB
in 100 years, we do not need a special strategy.

<details>
<summary>Vehicle state table</summary>

```sql
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
```
</details>

## 5.3 The initial state problem

The problem definition above states that the initial state of a vehicle is
***'commissioned'***. One can remember to implement an insertion on the second
table, or ask PostgreSQL to do it for her, which will handle all the error cases
much more graciously.

<details>
<summary>Implementation</summary>

```sql
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
```
```sql
CREATE TRIGGER
    after_insert_vehicles
AFTER INSERT ON
    vehicles
FOR EACH ROW EXECUTE FUNCTION 
    fn_vehicle_initial_state();
```

A couple of notes:

* We want an AFTER action because otherwise the foreign key constrain
  will fail as the row is not yet inserted
* Both insert action happen on the same transaction horizon, obviously not
  the same ctid though
* Both inserts have to succeed otherwise, both inserts fail. This
  guarantees that there will not be vehicle entries without at least one
  vehicle_state entry

</details>

## 5.4 Vehicle location log

For the location log though, we expect a substantial amount of inserts. However
only the latest few entries will be necessary for the day to day operations. The
rest we can move away into an archive which can be used for analytical business
queries.

The relation ***should*** contain:

* The vehicle identifier
* The date and time of the ping from the tracker
* The location of the vehicle

<details>
<summary>Implementation</summary>

```sql
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
```

</details>

## 5.5 Vehicle location validator

We ***must*** make certain that we do not register invalid locations.

We can not, and really should not, use ***CHECK constraints***. They can not
reference data on other tables. They ***must*** be immutable, meaning that the
same input should always generate the same result. If they depend on other data
then that requirement will fail when the dependent data changes.

If all what we need is to guarantee that the data on the time of insertion are
correct, then a before insert trigger would do the job. That would also make
certain that dump and restore would work, as triggers are deactivated during
restore and are only enabled at the end of the restore process.

<details>
<summary>Implementation</summary>

```sql
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
    vehicle_location_insert check
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
```

</details>

## 5.6 Vehicle location archiver

We can move older entries in an archive schema. There we can still maintain
them for analytical queries ***and*** make certain that the day to day
operations do not degrade due to excessive relation size.

We need to repeat this definition in a new schema, named archive. Then we need
to launch a process that will run every X days and move data from the public
schema to the archive schema.

<details>
<summary>Implementation</summary>

```sql
CREATE SCHEMA IF NOT EXISTS archive;

CREATE TABLE archive.vehicle_location (
    LIKE public.vehicle_location
);
COMMENT ON TABLE
    archive.vehicle_location
IS
    'Historical entries of vehicle_location table'
;
```

Then we create the archive function and attach it to a delete trigger.

```sql
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
```

Finally we create a cron job to archive location events every day five minutes
past midnight.

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT
    cron.schedule(
        '5 0 * * *',                                    -- Minute Hour Day Month Weekday
        $body$
            DELETE FROM
                public.vehicle_location
            WHERE
                timestamp < NOW() - INTERVAL '1 WEEK'
        $body$
    );
```
</details>

## 5.7 Reality bites

The observant reader would have spotted right now that our state guarantees are
rather flimsy. Nothing can prevent from a deleting or updating a row, or marking
vehicles into states that are not sensical. The first problem is solved by using
privileges for users that restrict such actions. We will see one way to solve
that later. The second problem requires a slightly more involved solution, which
we can implement with almost everything we have seen so far.

<details>
<summary>Implementation</summary>

Identify what the allowed state transitions are.

```
                 +------------------+
                 |   commissioned   |<-----+
                 +------------------+      |
                          |                |
                          v                |
                 +------------------+      |
                 |     off duty     |      |
                 +------------------+      |
                   |            |          |
                   v            v          |
           +------------+   +--------------+---+
           |  on duty   |   |  decommissioned  |
           +------------+   +------------------+
                |   ^
                v   |
          +------------------+
          |     assigned     |
          +------------------+

```

Create and populate a helper table that records the transitions.

```sql
CREATE TABLE valid_vehicle_state_transitions (
    from_state vehicle_state_enum NOT NULL,
    to_state vehicle_state_enum NOT NULL,
    PRIMARY KEY (from_state, to_state)
);

INSERT INTO
    valid_vehicle_state_transitions (from_state, to_state)
VALUES
    ('commissioned', 'off duty'),
    ('off duty', 'decommissioned'),
    ('off duty', 'on duty'),
    ('on duty', 'assigned'),
    ('on duty', 'off duty'),
    ('assigned', 'on duty'),
    ('decommissioned', 'commissioned')
;
```

Then create a Finite State Machine function to check the new vehicle_state
against the valid transitions table.

```sql
CREATE OR REPLACE FUNCTION fn_state_fsm_insert()
RETURNS TRIGGER AS $$
DECLARE
	previous_state    vehicle_state.state%TYPE;
	next_state        vehicle_state.state%TYPE := NEW.state;
	is_valid          BOOLEAN := FALSE;
BEGIN
	SELECT
        state INTO previous_state
	FROM
        vehicle_state
	WHERE
        vehicle_id = NEW.vehicle_id
	ORDER BY
        timestamp DESC
	LIMIT 1;

	IF previous_state IS NULL THEN
		IF next_state <> 'commissioned' THEN
		    RAISE EXCEPTION 'Invalid state transition for vehicle %: NULL → %',
				NEW.vehicle_id, next_state
            USING HINT = 'Initial state must be "commissioned"';
		END IF;
		RETURN NEW;
	END IF;

    PERFORM
        1
    FROM
        valid_vehicle_state_transitions
    WHERE
        from_state = previous_state AND
        to_state = next_state;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid state transition for vehicle %: % → %',
            NEW.vehicle_id, previous_state, next_state;
    END IF;

	RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Finally, attach it to a before insert into vehicle_state trigger.

```sql
CREATE TRIGGER
    before_insert_vehicle_state
BEFORE INSERT ON
    vehicle_state
FOR EACH ROW EXECUTE FUNCTION 
    fn_state_fsm_insert();

```
</summary>
