---
title: Import OSM Data
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
  href: chapter3.html
  label: Schemata
  title: Schemata

next_chapter:
  href: chapter5.html
  label: Vehicle log
  title: Vehicle log

custom_toc:
  - {href: import-osm-data, label: 4. Import OSM Data}
  - {href: import, label: 4.1 Import}
  - {href: clean-up, label: 4.2 Clean up}

---

# 4. Import OSM Data

OpenStreetMaps provides data in various formats, ranging from pure binary to
human readable like XML or json. There are also many binaries that are able to
convert osm files from one format to another. Similarly, there are many ways to
import osm data into PostgreSQL. The most commonly used is ***osm2pgsql***.

## 4.1 Import

***osm2pgsql*** comes with a wealth of options during importing. We will confine
ourselves to the most basic one, that solves our need. It will generate a
default set of tables and attributes which we can then manipulate based on our
needs.

But first we need a schema:

```sql
CREATE SCHEMA IF NOT EXISTS osm_raw_data;
```

And we need to install the PostGIS extension:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
```

Then we can import the data:

```bash
osm2pgsql \
    --create \
    --database postgres://georgios@localhost/emergency_vehicles_lesbos \
    --schema osm_raw_data \
    --proj 2100 \
    osmdata/Lesbos.osm;
```

## 4.2 Clean up

Since what we are only going to be using data within the island of Lesvos, we
can delete what ever else got included in our crude bounding box while querying
the overpass API.

Ideally we would like to use an attribute like **admin_level** but that was not
populated. We can query based on **name** and **place** instead.

Note the use of the **public** schema in the search_path. We have installed the
extension ***PostGIS*** there. If we didn't include it we would have had to
explicitly cast the ***ST_*** family of functions we are using, as well as the
types of the geographic or geometric attributes.

```sql
SET search_path TO osm_raw_data, public;

DELETE FROM
    planet_osm_polygon AS dest
USING
    planet_osm_polygon AS src
WHERE
    NOT ST_Within(dest.way, src.way) AND
    src.name = 'Λέσβος' AND
    src.place = 'island'
;

DELETE FROM
    planet_osm_roads AS dest
USING
    planet_osm_polygon AS src
WHERE
    NOT ST_Within(dest.way, src.way) AND
    src.name = 'Λέσβος' AND
    src.place = 'island'
;

DELETE FROM
    planet_osm_point AS dest
USING
    planet_osm_polygon AS src
WHERE
    NOT ST_Within(dest.way, src.way) AND
    src.name = 'Λέσβος' AND
    src.place = 'island'
;

DELETE FROM
    planet_osm_line AS dest
USING
    planet_osm_polygon AS src
WHERE
    NOT ST_Within(dest.way, src.way) AND
    src.name = 'Λέσβος' AND
    src.place = 'island'
;
```
