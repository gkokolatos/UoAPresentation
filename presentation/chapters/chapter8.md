---
title: Application Interface
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
  href: chapter7.html
  label: Schema testing
  title: Schema testing

next_chapter:
  href: chapter9.html
  label: Generating vehicle data
  title: Generating vehicle data

custom_toc:
  - {href: fleet-management, label: 8.1 Fleet management}
  - {href: , label: 8.2 Fleet's latest information}
  - {href: , label: 8.3 Fleet's concise information}
  - {href: , label: 8.4 Fleet's latest concise information}
---

# 8 Application Interface

Important challenges that quite some teams face during the product life-cycle
revolve around product updates, system upgrades, A/B testing, and canary
deployments. Many times, it is important to be able to maintain more than one
versions of the application level software available, which may target tables
with different definitions.

One good practice to help mitigate those problems, is to decouple the
application level code, from the internals of the database schema. This can be
accomplished by offering a set of views and functions for the application to
interact with. This set of objects should remain stable within a version but the
underline tables and functions may change.

Finally, such a design practice, provides the added benefit of user control. For
example, one can restrict access to the underline tables for users, but allow
them to use views and functions in specific schemas.

Let us create the first version of the interface.

```sql
CREATE SCHEMA v1_0_0;
COMMENT ON SCHEMA
	v1_0_0
IS 'Version 1.0.0 of the application interface';
```

## 8.1 Fleet management

**As a application I want to**:

* be able to add new vehicles
* be able to delete old vehicles that have not been involved in emergencies
* be able to assign states to a vehicle
* be able to assign location to a vehicle

**So that**:

* I can reflect the changes of the fleet size
* I can reflect the changes of the fleet availability
* I can know where the vehicles are, or have recently been

**Because**:

* I need to be able to manage it

<details>
<summary>Addition</summary>
```sql
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
```
</details>

<details>
<summary>Deletion</summary>
```sql
SET search_path TO v1_0_0, public;

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
```
</details>

<details>
<summary>State assignment</summary>
```sql
--
-- This will NOT return null on non existing fleet_id
-- because it is a single row insert
--
CREATE OR REPLACE FUNCTION v1_0_0.assign_vehicle_state(
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

```
</details>


<details>
<summary>Location assignment</summary>
```sql
--
-- This will return null on non existing fleet_id
-- because it is a bulk insert
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
		vehicles
	WHERE
		fleet_id = in_fleet_id
	RETURNING
		location_id;
$$
LANGUAGE sql;

```
</details>

## 8.2 Fleet's latest information

**As a application I want to**:

* be able to get the all the vehicles' latest states
* be able to get the all the vehicles' latest location

**So that**:

* I can easily access their latest details

**Because**:

* I need to be able to oversee it

<details>
<summary>Latest state</summary>

Distinct on is PostgreSQL extension of the SQL standard. It will get interpreted
using the rules defined in the *ORDER BY* clause. If *ORDER BY* is not used,
then the result *will be unpredictable*.

```sql
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

```
</details>

<details>
<summary>Latest location</summary>

```sql
CREATE OR REPLACE VIEW v1_0_0.vehicle_latest_location AS
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

```
</details>

## 8.3 Fleet's concise information

**As a application I want to**:

* be able to get the all the vehicles' holistic information

**So that**:

* I can get a present and past overview of the fleet

**Because**:

* I need to generate strategies

The above requirement, dictates that we join all the vehicle relations so that
we can know in which locations a vehicle has been ***and*** which state it had
when there. Practically, we need to find the timestamps that a vehicle changed
state and based on that, retrieve it's location information.

PostgreSQL implements *Common Table Expressions* or CTEs, as a means to break
down large queries into separate auxiliary statements. They really improve
readability, extend usability, for example in their *RECURSIVE* form, but they
do come with some caveats.

<details>
<summary>Implementation</summary>

```sql
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
```
</details>

## 8.4 Fleet's latest concise information

Combining the above strategies, we can trivially retrieve the latest state
***and*** location for each vehicle in the fleet.

<details>
<summary>Implementation</summary>

```sql
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
```
</details>
