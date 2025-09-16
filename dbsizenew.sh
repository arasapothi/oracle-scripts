#!/bin/bash

# Script to get database names from crsctl, derive database name from ps -ef | grep pmon
# (excluding asm*, apx*, mgmtdb and removing _1/_2 suffixes), set Oracle environment
# by sourcing the database name directly (e.g., . test), connect to each PDB,
# and get the used size of all PDBs in a single-node RAC database.
# Assumptions:
# - Run as the oracle user with access to crsctl and sqlplus.
# - Grid Infrastructure is installed, and crsctl is in PATH.
# - Sourcing the database name (e.g., . test) sets ORACLE_SID, ORACLE_HOME, and PATH.
# - Databases and instances are running; offline databases/PDBs are skipped.
# - Uses OS authentication (/ as sysdba) for SQL*Plus connections.
# - Assumes Container Databases (CDBs) contain PDBs.
# - Single-node RAC, so database name can be obtained from pmon process.

# Exit on error
set -e

# Get database names from crsctl (filter for ora.<dbname>.db resources)
dbs=$(crsctl status resource -t | grep -E '^ora\..*\.db$' | awk '{print $1}' | sed 's/ora\.//g' | sed 's/\.db//g' | sort -u)

if [ -z "$dbs" ]; then
  echo "No databases found in the RAC cluster."
  exit 1
fi

# Print header for output
printf "%-20s %-15s\n" "database" "database_size"

# Loop through each database
for db in $dbs; do
  # Get database name from pmon process, excluding asm*, apx*, mgmtdb, and remove _1 or _2 suffix
  dbname=$(ps -ef | grep [o]ra_pmon_ | grep -i "$db" | grep -vE 'asm|apx|mgmtdb' | awk '{print $NF}' | sed 's/ora_pmon_//g' | sed 's/_[1-2]$//g')
  
  if [ -z "$dbname" ]; then
    echo "Database $db: No running pmon process found (excluding asm*, apx*, mgmtdb). Skipping."
    continue
  fi
  
  # Set Oracle environment by sourcing the database name directly (e.g., . test)
  . $dbname > /dev/null 2>&1
  
  # Verify environment is set by checking sqlplus availability
  if ! command -v sqlplus >/dev/null 2>&1; then
    echo "Database $dbname: Failed to set Oracle environment or sqlplus not found. Skipping."
    continue
  fi
  
  # Get list of PDBs in the CDB
  pdbs=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT name FROM v\$pdbs WHERE name NOT IN ('PDB\$SEED');
EOF
)

  if [ $? -ne 0 ] || [ -z "$pdbs" ]; then
    echo "Database $dbname: No PDBs found or not a CDB. Skipping."
    continue
  fi

  # Loop through each PDB
  for pdb in $pdbs; do
    # SQL query to connect to PDB and get used database size (in GB)
    used_size=$(sqlplus -s / as sysdba <<EOF
ALTER SESSION SET CONTAINER = ${pdb};
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT 
  ROUND((SUM(total.bytes) - NVL(SUM(free.bytes), 0)) / 1024 / 1024 / 1024, 2)
FROM 
  (SELECT SUM(bytes) AS bytes FROM v\$datafile
   UNION ALL
   SELECT SUM(bytes) FROM v\$tempfile
   UNION ALL
   SELECT SUM(bytes) FROM v\$log) total,
  (SELECT SUM(bytes) AS bytes FROM dba_free_space) free;
EOF
)

    # Check if SQL*Plus command was successful
    if [ $? -ne 0 ]; then
      echo "Database $dbname, PDB $pdb: Failed to retrieve size information."
      continue
    fi

    # Output in specified format (lowercase PDB name, size in GB)
    printf "%-20s %-15.2f gb\n" "${pdb,,}" "$used_size"
  done
done