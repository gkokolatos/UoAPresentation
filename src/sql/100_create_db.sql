--
-- Database creation
--
-- Make sure that you can choose the desirable locale and an enconding
-- regardless of the values selected during initdb.
--

DROP DATABASE IF EXISTS emergency_vehicles_lesbos;

CREATE DATABASE
	emergency_vehicles_lesbos
ENCODING UTF8
LOCALE 'el_GR.UTF8'
TEMPLATE template0;

COMMENT ON DATABASE
	emergency_vehicles_lesbos
IS
	'Development database for emergency \
	 vehicle coordination project';
