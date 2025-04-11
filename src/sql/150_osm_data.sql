CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS osm_raw_data;

SELECT 1;
\g | osm2pgsql --create --database postgres://georgios@localhost/emergency_vehicles_lesbos --schema osm_raw_data --proj 2100 osmdata/Lesbos.osm;

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
