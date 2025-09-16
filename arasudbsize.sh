#!/bin/bash

# Script to derive database names from ps -ef | grep pmon (excluding asm*, apx*, mgmtdb,
# removing _1/_2 suffixes, converting to lowercase), set Oracle environment by sourcing
# the lowercase database name (e.g., . test), connect to CDB using 'sq', connect to each PDB,
# and output PDB name and used size (in GB) or "pdb is down" if inaccessible.
# Assumptions:
# - Run as the oracle user with access to sq.
# - Sourcing the lowercase database name sets ORACLE_SID, ORACLE_HOME, and PATH.
# - Databases are running; offline PDBs are reported as down without opening.
# - 'sq' connects to the CDB as sysdba.

set -e

dbs=$(ps -ef | grep [o]ra_pmon_ | grep -vE 'asm|apx|mgmtdb' | awk '{print $NF}' | sed 's/ora_pmon_//g' | sed 's/_[1-2]$//g' | tr '[:upper:]' '[:lower:]' | sort -u)

if [ -z "$dbs" ]; then
  echo "DEBUG: No databases found." >&2
  exit 1
fi

for db in $dbs; do
  if ! . $db >/dev/null 2>&1; then
    echo "DEBUG: Database $db: Failed to source environment." >&2
    continue
  fi

  if ! command -v sq >/dev/null 2>&1; then
    echo "DEBUG: Database $db: sq not found." >&2
    continue
  fi

  pdbs_status=$(sq <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT name, open_mode FROM v\$pdbs WHERE name NOT IN ('PDB\$SEED');
EOF
)

  if [ $? -ne 0 ]; then
    echo "DEBUG: Database $db: Failed to query v\$pdbs." >&2
    continue
  fi

  while read -r pdb status; do
    if [ -z "$pdb" ] || [ -z "$status" ]; then
      continue
    fi

    if [ "$status" != "READ WRITE" ]; then
      printf "%-20s %-15s\n" "${pdb,,}" "pdb is down"
    else
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
        echo "DEBUG: Database $db, PDB $pdb: Failed to get size." >&2
        continue
      fi

      printf "%-20s %-15.2f\n" "${pdb,,}" "$used_size"
    fi
  done <<< "$pdbs_status"
done