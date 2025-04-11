---
title: Emergencies
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
  href: chapter5.html
  label: Vehicle log
  title: Vehicle log

next_chapter:
  href: chapter7.html
  label: Schema Testing
  title: Schema Testing

custom_toc:
  - {href: emergencies, label: 6. Emergencies}
  - {href: the-base-relation, label: 6.1 The base relation}
  - {href: emergency-state, label: 6.2 Emergency state}
  - {href: assign-vehicle-to-emergency, label: 6.3 Assign vehicle to emergency}
  - {href: detach-vehicles-on-emergency-conclussion, label: 6.4 Detach vehicles on emergency conclussion}
---

# 6. Emergencies

**As a user I want to**:

* be able to declare an emergency
* assign one or more available vehicles to it
* detach one or more assigned vehicles from it

**So that**:

* We can be respond fast to the emergency
* We can make efficient use of our fleet

**Because**:

* Response time is essential 
* Our resources are valuable

### Problem definitions 

* An emergency is defined by its ***location***
* An emergency happens in a point
* An emergency ***must*** have ***one and only one*** of the following states on
  any given time:
  * declared               - *the initial state*
  * active                 - *it is on going*
  * concluded              - *it has been handled*
* We do not expect many emergencies, in the ballpark of tens per day
* Each emergency must be in Lesbos mainland.
* For a vehicle to be able to be assigned to it, it ***must*** have state *'on duty'*
* Each attached vehicle ***must*** have state *'assigned'*
* Each attached vehicle when detaches ***must*** have state *'on duty'*
* When the emergency concludes, all attached vehicles ***must*** be detached

## 6.1 The base relation

Already from the problem definition becomes apparent that we can not express it
all in a single relation. The base relation ***should*** contain:

* The location
* A human readable description

The location ***must*** be valid. We can reuse the location check function from
the previous chapter, provided that we maintain the same column definition.

<details>
<summary>Implementation</summary>

```sql
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
```

</details>

## 6.2 Emergency state

Similarly to the previous chapter, a dedicated enumerated type is needed as well
as trigger to handle the initial state.

<details>
<summary>Implementation</summary>

```sql
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
```

</details>


## 6.3 Assign vehicle to emergency

The basic requirements as are expressed in the problem definition are easily
expressed in the relation. It is possible though, for a vehicle to be assigned
to an emergency, then decide that the vehicle was not needed, to then change her
mind again and re-assign it. Adding an extra column to the design, will require
minimum storage space but will greatly increase the flexibility of the feature.

<details>
<summary>Implementation</summary>

```sql
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

```

</details>

The more advanced requirement of a vehicle having a specific state in order to
be able to be assigned on an emergency, then switching to a different state and
maintaining both tables in sync, requires a more advanced implementation. The
upside is that it is not fundamentally different from what we have seen so far.

<details>
<summary>Implementation</summary>

```sql
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
```

</details>

Finally attach that function into a before insert trigger.

<details>
<summary>Implementation</summary>

```sql
CREATE TRIGGER
	before_assign_vehicle
BEFORE INSERT ON
	emergency_vehicles
FOR EACH ROW EXECUTE FUNCTION 
	fn_assign_vehicle();
```

</details>

## 6.4 Detach vehicles on emergency conclussion

The final requirement dictates that when the emergency concludes, all attached
vehicles have to be marked as available for the next emergency with state *"on
duty"*. Given our design, that means that when the emergency is marked as
concluded in the emergency_state relation, then we have to find all the vehicles
currently attached to that emergency and detach them by setting their status as
*'detached'* in the emergency_vehicles table. The act of detaching them, should
fire the above trigger, which will take care the vehicle_state table for us.

We have to be cautious to not select vehicles which might have been attached and
then detached from the emergency.

<details>
<summary>Implementation</summary>

```sql
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

```
</details>

Finally, attach that function in a trigger when the emergency is marked as
*'concluded'*.

<details>
<summary>Implementation</summary>

```sql
CREATE TRIGGER
	after_conclude_emergency
AFTER INSERT ON
	emergency_state
FOR EACH ROW 
WHEN (NEW.state = 'concluded')
EXECUTE FUNCTION
	fn_conclude_emergency();
```
</details>


