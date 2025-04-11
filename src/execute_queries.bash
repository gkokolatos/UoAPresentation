#!/usr/bin/env bash

set -eu
#
#
# Check if the file is sourced or executed
#
# it examines FUNCNAME to determine if the current file is sourced. It contains
# the stack's function names, obviously currently executing being the first.
#
# Usage: __is_sourced
#
__is_sourced() {
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		&& [ "${FUNCNAME[0]}" = '__is_sourced' ] \
		&& [ "${FUNCNAME[1]}" = 'source' ]
}

execute_file_sql() {
	local connstring="$1"
	local file="$2"

	if [ ! -f "$file" ]; then
	  echo "File $file not found"
	  exit 1
	fi

	psql "$connstring" --file "$file"
}

#
#
# Helper function to create and populate the datadir
#
# Manages datadir creation and configuration management.
#
# Usage: create_datadir datadir [force|ignore]
#                       Creates a data directory or errors out
#     where:
#         datadir       The data directory path
#         force         Removes an existing data directory
#         ignore        Ignores data directory creation if one already exists
create_datadir() {
    local datadir="$1"
    local arg="$2"
 
    case "$arg" in
        force)
            echo "Forcefully recreating the PostgreSQL database..."

            # Stop immediately since the directory will be erased
            if ! pg_ctl -D "$datadir" -m immediate stop; then
                 # Nothing to do
	             echo "Continuing..."
            fi

            rm -rf "$datadir" || true
            if [ -d "$datadir" ]; then
                echo "Error: Failed to remove '$datadir'"
                exit 1
            fi

            if ! pg_ctl -D "$datadir" initdb; then
                echo "Error: Failed to initialize the PostgreSQL database" >&2
                exit 1
            fi
        ;;
        ignore)
            if [ -d "$datadir" ]; then
                echo "$datadir exits, skipping init..."
            elif ! pg_ctl -D "$datadir" initdb; then
                echo "Error: Failed to initialize the PostgreSQL database" >&2
                exit 1
            fi
        ;;
        *)
            if ! pg_ctl -D "$datadir" initdb; then
                echo "Error: Failed to initialize the PostgreSQL database" >&2
                exit 1
            fi
        ;;
    esac

    cat <<EOF >> "$datadir"/postgresql.conf
shared_preload_libraries = 'pg_cron'
cron.database_name = 'emergency_vehicles_lesbos'
EOF

}


#
# Helper function to start server
#
# Verifies that PostgreSQL is ready to accept connections as it is not
# uncommon for pg_ctl start to return before the server can accept
# connections.
#
start_server() {
  local datadir="$1"
  shift

  local max_attempts=100
  local attempt=0

  if ! pg_ctl  -D "$datadir" -l "$datadir/startup.log" start; then
     echo "Error: Failed to start the PostgreSQL server" >&2
     exit 1
  fi

  # Poor man's synch. Verify that the server is ready or exit
  while : ; do
    echo "Attempt #$((attempt+1)): Checking if PostgreSQL is ready..."
    pg_isready > /dev/null 2>&1  
  
    if [ $? -eq 0 ]; then
      echo "PostgreSQL is ready to accept connections"
      break
    fi
 
    # Keep the two operations close together
    attempt=$((attempt + 1))
    [ $attempt -lt $max_attempts ] || break 
    sleep 1
  done 

  if [ ! $attempt -lt $max_attempts ]; then
     echo "Error: PostgreSQL did not become ready after $max_attempts attempts"
     exit 1
  fi
}

main() {
	create_datadir "./data" "force"
	start_server "./data"

	execute_file_sql "postgres://georgios@localhost/postgres" "./src/sql/100_create_db.sql"
	execute_file_sql "postgres://georgios@localhost/emergency_vehicles_lesbos" "./src/sql/150_osm_data.sql"
	execute_file_sql "postgres://georgios@localhost/emergency_vehicles_lesbos" "./src/sql/200_vehicles.sql"
	execute_file_sql "postgres://georgios@localhost/emergency_vehicles_lesbos" "./src/sql/300_emergency.sql"
	execute_file_sql "postgres://georgios@localhost/emergency_vehicles_lesbos" "./src/sql/400_api.sql"
	execute_file_sql "postgres://georgios@localhost/emergency_vehicles_lesbos" "./src/sql/600_testing.sql"
	execute_file_sql "postgres://georgios@localhost/emergency_vehicles_lesbos" "./src/sql/700_pgrouting.sql"
}

if ! __is_sourced; then
	main "$@"
fi
