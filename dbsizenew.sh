#!/bin/bash

# Script to derive database names from ps -ef | grep pmon (excluding asm*, apx*, mgmtdb,
# removing _1/_2 suffixes, converting to lowercase), set Oracle environment by sourcing
# the lowercase database name (e.g., . test), connect to CDB using 'sq', connect to each PDB,
# and output only PDB name and used size (in GB) in a single-node RAC database.
# Assumptions:
# - Run as the oracle user with access to sq (alias/script for sqlplus / as sysdba).
# - Sourcing the lowercase database name (e.g., . test) sets ORACLE_SID, ORACLE_HOME, and PATH.
# - Databases and instances are running; offline databases/PDBs are skipped.
# - 'sq' connects directly to the CDB as sysdba.
# - Assumes Container Databases (CDBs) contain PDBs.
# - Single-node RAC, so database name can be obtained from pmon process.

# Exit on error
set -e

# Get database names from pmon process, excluding asm*, apx*, mgmtdb, remove _1 or _2 suffix,
# and convert to lowercase
dbs=$(ps -ef | grep [o]ra_pmon_ | grep -vE 'asm|apx|mgmtdb' | awk '{print $NF}' | sed 's/ora_pmon_//g' | sed 's/_[1-2]$//g' | tr '[:upper:]' '[:lower:]' | sort -u)

# Loop through each database
for db in $dbs; do
  # Set Oracle environment by sourcing the lowercase database name (e.g., . test)
  . $db >/dev/null 2>&1
  
  # Check if sq is available
  if ! command -v sq >/dev/null 2>&1; then
    continue
  fi
  
  # Get list of PDBs in the CDB
  pdbs=$(sq <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT name FROM v\$pdbs WHERE name NOT IN ('PDB\$SEED');
EOF
)

  if [ $? -ne 0 ] || [ -z "$pdbs" ]; then
    continue
  fi

  # Loop through each PDB
  for pdb in $pdbs; do
    # SQL query to connect to PDB and get used database size (in GB)
    used_size=$(sq <<EOF
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

    if [ $? -ne 0 ]; then
      continue
    fi

    # Output only PDB name (lowercase) and size (without 'gb')
    printf "%-20s %-15.2f\n" "${pdb,,}" "$used_size"
  done
done#!/bin/bash

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





#!/bin/bash

# Script to derive database names from ps -ef | grep pmon (excluding asm*, apx*, mgmtdb
# and removing _1/_2 suffixes), set Oracle environment by sourcing the database name
# directly (e.g., . test), connect to each PDB, and get the used size of all PDBs
# in a single-node RAC database.
# Assumptions:
# - Run as the oracle user with access to sqlplus.
# - Sourcing the database name (e.g., . test) sets ORACLE_SID, ORACLE_HOME, and PATH.
# - Databases and instances are running; offline databases/PDBs are skipped.
# - Uses OS authentication (/ as sysdba) for SQL*Plus connections.
# - Assumes Container Databases (CDBs) contain PDBs.
# - Single-node RAC, so database name can be obtained from pmon process.

# Exit on error
set -e

# Get database names from pmon process, excluding asm*, apx*, mgmtdb, and remove _1 or _2 suffix
dbs=$(ps -ef | grep [o]ra_pmon_ | grep -vE 'asm|apx|mgmtdb' | awk '{print $NF}' | sed 's/ora_pmon_//g' | sed 's/_[1-2]$//g' | sort -u)

if [ -z "$dbs" ]; then
  echo "No databases found in the pmon process list (excluding asm*, apx*, mgmtdb)."
  exit 1
fi

# Print header for output
printf "%-20s %-15s\n" "database" "database_size"

# Loop through each database
for db in $dbs; do
  # Set Oracle environment by sourcing the database name directly (e.g., . test)
  . $db > /dev/null 2>&1
  
  # Verify environment is set by checking sqlplus availability
  if ! command -v sqlplus >/dev/null 2>&1; then
    echo "Database $db: Failed to set Oracle environment or sqlplus not found. Skipping."
    continue
  fi
  
  # Get list of PDBs in the CDB
  pdbs=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT name FROM v\$pdbs WHERE name NOT IN ('PDB\$SEED');
EOF
)

  if [ $? -ne 0 ] || [ -z "$pdbs" ]; then
    echo "Database $db: No PDBs found or not a CDB. Skipping."
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
      echo "Database $db, PDB $pdb: Failed to retrieve size information."
      continue
    fi

    # Output in specified format (lowercase PDB name, size in GB)
    printf "%-20s %-15.2f gb\n" "${pdb,,}" "$used_size"
  done
done






#!/bin/bash

# Script to derive database names from ps -ef | grep pmon (excluding asm*, apx*, mgmtdb
# and removing _1/_2 suffixes), convert to lowercase, set Oracle environment by sourcing
# the lowercase database name directly (e.g., . test), connect to each PDB, and get the
# used size of all PDBs in a single-node RAC database.
# Assumptions:
# - Run as the oracle user with access to sqlplus.
# - Sourcing the lowercase database name (e.g., . test) sets ORACLE_SID, ORACLE_HOME, and PATH.
# - Databases and instances are running; offline databases/PDBs are skipped.
# - Uses OS authentication (/ as sysdba) for SQL*Plus connections.
# - Assumes Container Databases (CDBs) contain PDBs.
# - Single-node RAC, so database name can be obtained from pmon process.

# Exit on error
set -e

# Get database names from pmon process, excluding asm*, apx*, mgmtdb, remove _1 or _2 suffix,
# and convert to lowercase
dbs=$(ps -ef | grep [o]ra_pmon_ | grep -vE 'asm|apx|mgmtdb' | awk '{print $NF}' | sed 's/ora_pmon_//g' | sed 's/_[1-2]$//g' | tr '[:upper:]' '[:lower:]' | sort -u)

if [ -z "$dbs" ]; then
  echo "No databases found in the pmon process list (excluding asm*, apx*, mgmtdb)."
  exit 1
fi

# Print header for output
printf "%-20s %-15s\n" "database" "database_size"

# Loop through each database
for db in $dbs; do
  # Set Oracle environment by sourcing the lowercase database name directly (e.g., . test)
  . $db > /dev/null 2>&1
  
  # Verify environment is set by checking sqlplus availability
  if ! command -v sqlplus >/dev/null 2>&1; then
    echo "Database $db: Failed to set Oracle environment or sqlplus not found. Skipping."
    continue
  fi
  
  # Get list of PDBs in the CDB
  pdbs=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT name FROM v\$pdbs WHERE name NOT IN ('PDB\$SEED');
EOF
)

  if [ $? -ne 0 ] || [ -z "$pdbs" ]; then
    echo "Database $db: No PDBs found or not a CDB. Skipping."
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
      echo "Database $db, PDB $pdb: Failed to retrieve size information."
      continue
    fi

    # Output in specified format (lowercase PDB name, size in GB)
    printf "%-20s %-15.2f gb\n" "${pdb,,}" "$used_size"
  done
done





#!/bin/bash

# Script to derive database names from ps -ef | grep pmon (excluding asm*, apx*, mgmtdb,
# removing _1/_2 suffixes, converting to lowercase), set Oracle environment by sourcing
# the lowercase database name (e.g., . test), connect to CDB using 'sq', connect to each PDB,
# and output only PDB name and used size (in GB) in a single-node RAC database.
# Assumptions:
# - Run as the oracle user with access to sq (alias/script for sqlplus / as sysdba).
# - Sourcing the lowercase database name (e.g., . test) sets ORACLE_SID, ORACLE_HOME, and PATH.
# - Databases and instances are running; offline databases/PDBs are skipped.
# - 'sq' connects directly to the CDB as sysdba.
# - Assumes Container Databases (CDBs) contain PDBs.
# - Single-node RAC, so database name can be obtained from pmon process.

# Exit on error
set -e

# Get database names from pmon process, excluding asm*, apx*, mgmtdb, remove _1 or _2 suffix,
# and convert to lowercase
dbs=$(ps -ef | grep [o]ra_pmon_ | grep -vE 'asm|apx|mgmtdb' | awk '{print $NF}' | sed 's/ora_pmon_//g' | sed 's/_[1-2]$//g' | tr '[:upper:]' '[:lower:]' | sort -u)

# Loop through each database
for db in $dbs; do
  # Set Oracle environment by sourcing the lowercase database name (e.g., . test)
  . $db >/dev/null 2>&1
  
  # Check if sq is available
  if ! command -v sq >/dev/null 2>&1; then
    continue
  fi
  
  # Get list of PDBs in the CDB
  pdbs=$(sq <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT name FROM v\$pdbs WHERE name NOT IN ('PDB\$SEED');
EOF
)

  if [ $? -ne 0 ] || [ -z "$pdbs" ]; then
    continue
  fi

  # Loop through each PDB
  for pdb in $pdbs; do
    # SQL query to connect to PDB and get used database size (in GB)
    used_size=$(sq <<EOF
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

    if [ $? -ne 0 ]; then
      continue
    fi

    # Output only PDB name (lowercase) and size (without 'gb')
    printf "%-20s %-15.2f\n" "${pdb,,}" "$used_size"
  done
done