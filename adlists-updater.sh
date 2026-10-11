#!/usr/bin/env bash
set -euo pipefail

# author  : Javan Rasokat (javan.de)
# license : gplv3

# we need to be root to have write access to gravity.db
if (( EUID != 0 )); then
  echo 'Warning: Please run as root' >&2
  exit 1
fi

# check if we're actually on a pihole (and a new version at that)
if ! command -v pihole > /dev/null ; then
  echo 'Error: You must run this on a pihole!' >&2
  exit 1
fi

PIHOLE_COMMAND='/usr/local/bin/pihole'
GRAVITY_DB_FILE='/etc/pihole/gravity.db'
WORKDIR="${WORKDIR:-/opt/ya-pihole-list}"
ADLIST_LOCAL="${WORKDIR}/adlists.list.updater"
ADLIST_TMP="${WORKDIR}/adlists.list.updater.tmp"
ADLIST_SOURCE='https://raw.githubusercontent.com/avoidik/ya-pihole-list/master/adlists.list.updater'
GRAVITY_DB_TABLE='adlist'
UPDATE_TS="$(date --utc +'%s')"

mkdir -p "$WORKDIR"

case "${1:-0}" in
  0) update_cmd=0 ;;
  1) update_cmd=1 ;;
  *) echo "Usage: $0 [0|1]" >&2; exit 2 ;;
esac

if [[ "$update_cmd" == 1 ]]; then
  # update raspbian
  echo 'Info: Updating Raspbian'
  DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y

  # update pihole
  echo 'Info: Updating Pi-hole'
  pihole updatePihole
fi

# update gravity table (create or migrate if not exists yet)
echo 'Info: Create or migrate gravity.db table if not exists yet'
pihole updateGravity

# download latest adlists list
echo "Info: Download latest adlists list to ${ADLIST_LOCAL}"
curl -fsSL "${ADLIST_SOURCE}" -o "${ADLIST_LOCAL}"

# add lists to gravity db
# Migrate list files to new database
if [[ -e "${ADLIST_LOCAL}" ]]; then
  # Store adlist domains in database
  echo "Info: Adding content of ${ADLIST_LOCAL} into gravity database"

  # Get MAX(id) when INSERTing into this table
  tablerowid=$(sqlite3 "$GRAVITY_DB_FILE" "SELECT MAX(id) FROM ${GRAVITY_DB_TABLE};")
  if [[ -z "$tablerowid" ]]; then
    tablerowid=0
  fi
  tablerowid=$((tablerowid+1))

  # Loop over all domains in ${ADLIST_LOCAL} file
  # Read file line by line
  grep -v '^ *#' < "${ADLIST_LOCAL}" | while IFS= read -r sourcelisturl ; do
    # Only add non-empty lines
    if [[ -n "${sourcelisturl}" ]]; then
      # Adlist table format
      echo "${tablerowid},\"${sourcelisturl}\",1,${UPDATE_TS},${UPDATE_TS},\"Added by Updater\",${UPDATE_TS},0,0,0,0,0" >> "${ADLIST_TMP}"
      tablerowid=$((tablerowid+1))
    fi
  done

  # Store domains in database table specified by ${GRAVITY_DB_TABLE}
  # Use printf as .mode and .import need to be on separate lines
  # see https://unix.stackexchange.com/a/445615/83260
  if output=$(printf '.timeout 30000\n.mode csv\n.import "%s" %s\n' \ "$ADLIST_TMP" "$GRAVITY_DB_TABLE" | sqlite3 -batch "$GRAVITY_DB_FILE" 2>&1); then
    status=0
  else
    status=$?
  fi

  # delete temporary file
  rm -f -- "$ADLIST_TMP"

  if (( status != 0 )); then
    printf 'Warning: Import into %s failed:\n%s\n' "$GRAVITY_DB_FILE" "$output" >&2
  else
    echo 'Info: Successfully inserted the adlists list'
  fi
fi

# update gravity table (activate the changes to the gravity.db)
echo "Info: Caling 'pihole -g' because of the changes to the gravity.db"
pihole updateGravity
