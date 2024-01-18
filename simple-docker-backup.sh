#!/bin/bash
# vim:et:ai:sw=2:tw=0
#
# simple-docker-backup.sh
# This is a more or less simple docker backup tool for docker-compose.
# It is limited to running containers only.
#
# copyright (c) 2023 chillje, GPL version 3

IAM="$(basename "${0}")"
IAM_PATH="$(cd "$(dirname "$0")" && pwd)"
IAM_INI="${IAM:0:-3}.ini"

[ -f "${IAM_PATH}/${IAM_INI}" ] && source "${IAM_PATH}/${IAM_INI}"
BACKUP_PATH=${BACKUP_PATH:-""}
CONTAINER_NAMES=${CONTAINER_NAMES:-""}

# Help function.
help() {
  echo "usage ${IAM}: [OPTION...] [some-docker-compose-project-name]"
  warn "This is limited to running containers only"
  warn "Define your containers in the script in \"\$CONTAINER_NAMES\""
  warn "or use the ini-file simple-docker-backup.ini"
  cat << EOF
OPTIONs:
 -a|--all          backup all running docker-compose container
 -p|--postgres     create postgres db backup
 -s|--storage      create persistent storage backup
 -c|--config       also save whole config folder (incl. docker-compose.yml)
 -d|--delete       just keep the last 10 backups and delete the latter
 -h|--help         print this help, then exit

examples:
 * ${IAM} -s -c
 * ${IAM} -s -c some-docker-compose-project-name
EOF
}

# This function defines the used date format.
isodate() {
  date +%Y-%m-%dT%H%M%S
}

# Special kind of echo
warn() { printf "\033[31m$1\033[0m\n" >&2; }

# Function to check for dependencys.
depCheck() {
  local deps=(tar jq rsync)
  local missingDeps
  for (( i=0; i<${#deps[@]}; i++))
  do
    [ -z $(command -v ${deps[$i]}) ] && {
      if [ "${deps[$i]}" == "pg_dumpall" ]
      then
          missingDeps+=("postgresql-client")
      else
          missingDeps+=("${deps[$i]}")
      fi
    }
  done
  [ ! -z ${missingDeps} ] && apt-get install -y "${missingDeps[@]}" 
}

docker_storage_backup() {
  local service_name=${1}

  mapfile -t cnames < <(docker ps --filter "label=com.docker.compose.project=$service_name" --format "{{.Names}}")

  for container in "${cnames[@]}"; do

    echo "Backup for \"$container\" started.."

    [ -d ${BACKUP_PATH}/${service_name} ] || mkdir -m 700 ${BACKUP_PATH}/${service_name}
    [ -d ${BACKUP_PATH}/${service_name} ] || { 
      warn "Backup path ${BACKUP_PATH}/${service_name} not existent, exiting.."
      exit 1 
    }

    mapfile -t cvolumes< <(
      docker inspect ${container} | jq -r '.[].Mounts[] | select(.Type == "volume") | .Destination')

    # create backup from persistent storage volume
    [ ${#cvolumes[@]} -gt 0 ] && {
      echo "Creating volume backup for container \"${container}\" of docker service \"${service_name}\"."
      docker run --rm --volumes-from ${container} -v ${BACKUP_PATH}/${service_name}/:/backup ubuntu tar czf /backup/${date}-${container}-volumes.tgz ${cvolumes[@]}
    } || {
      warn "No volumes in container \"${container}\" of docker service \"${service_name}\", skipping.."
    }

  done

  [ -n "${PRM_CONFIG}" ] && {

    local compose_dir=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' ${cnames[0]})

    echo "Creating config backup of docker service \"${service_name}\"."
    tar czf ${BACKUP_PATH}/${service_name}/${date}-${service_name}-compose.tgz $compose_dir
    [ -f "${BACKUP_PATH}/${service_name}/${date}-${service_name}-compose.tgz" ] || {
      warn "Could not backup compose config dirf for \"${service_name}\", exiting.."
      exit 1
    }
  }

  [ "$service_name" != "$(echo $CONTAINER_NAMES | awk -F\  '{print $NF}')" ] && echo
}

docker_postgres_backup() {
  local service_name=${1}

  mapfile -t cnames < <(docker ps --filter "label=com.docker.compose.project=$service_name" --format "{{.Names}}")

  for container in "${cnames[@]}"; do

    echo "Check if pg_dumpall in \"${container}\".."
    [ $(docker exec ${container} which pg_dumpall) ] && {
      echo "Postgre sql backup for \"$container\" started.."

      [ -d ${BACKUP_PATH}/${service_name} ] || mkdir -m 700 ${BACKUP_PATH}/${service_name}
      [ -d ${BACKUP_PATH}/${service_name} ] || { 
        warn "Backup path \"${BACKUP_PATH}/${service_name}\" not existent, exiting.."
        exit 1 
      }

      local postgre_user=$(docker exec -i $container sh -c "echo \$POSTGRES_USER" | sed 's/[^A-Za-z0-9 ]//g')
      [ "${postgre_user}" != "" ] && {
        echo "Creating \"${BACKUP_PATH}/${service_name}/${date}-${container}-postgres.dumpall.gz\""
        docker exec ${container} pg_dumpall -U $postgre_user | gzip > "${BACKUP_PATH}/${service_name}/${date}-${container}-postgres.dumpall.gz"
      } || {
        warn "Can't extract postgres user of container \"$container\" from docker service \"${service_name}\", skipping.."
      }
    } || {
      warn "No \"pg_dumpall\" in container \"$container\" from docker service \"${service_name}\", skipping.."
    }

  done

  [ "$service_name" != "$(echo $CONTAINER_NAMES | awk -F\  '{print $NF}')" ] && echo
}

#docker_mariadb_backup() {
#  # FIXME
#}

cleanup() {
  local service_name=${1}

  [ -d ${BACKUP_PATH}/${service_name} ] && {
    find ${BACKUP_PATH}/${service_name}/*-volumes.tgz -type f | head -n -10 | xargs rm -fv
    find ${BACKUP_PATH}/${service_name}/*-compose.tgz -type f | head -n -10 | xargs rm -fv
    find ${BACKUP_PATH}/${service_name}/*-postgres.dumpall -type f | head -n -10 | xargs rm -fv
  } || {
    echo "No backups for container \"${service_name}\" found, skipping.."
  }
}

# This is the main function.
main() {

  date=$(isodate)

  # Check for needed dependencys.
  depCheck

  # Check if we have listed containers
  [ -z "$CONTAINER_NAMES" ] && {
    warn "${IAM}: Need at least one docker container in env \"\$CONTAINER_NAMES\", exiting.."
    exit 1
  }


  [ ! -d ${BACKUP_PATH} ] && {
    warn "${IAM}: Backup-Path \"${BACKUP_PATH}\" nonexistend."
    echo "${IAM}: Please create the \"${BACKUP_PATH}\" by yourself."
    exit 1
  }

  # get services via args 
  [ ${#} -gt 0 ] && CONTAINER_NAMES="${@}"

  # backup all containers
  [ -n "${PRM_ALL_CONTAINERS}" ] && {
    unset CONTAINER_NAMES
    mapfile -t CONTAINER_NAMES< <(docker ps --format "{{.Names}}")
  }

  [ -n "${PRM_STORAGE}" ] && {
    # Start backup for all containers
    for container in ${CONTAINER_NAMES[@]}; do
      docker_storage_backup $container
    done
  }

  [ -n "${PRM_POSTGRES}" ] && {
    # Start backup for all containers
    for container in ${CONTAINER_NAMES[@]}; do
    docker_postgres_backup $container
    done
  }

  [ -n "${PRM_DELETE}" ] && {
    for container in ${CONTAINER_NAMES[@]}; do
      cleanup $container
    done
  }
}

## need root
[ "$(id -u)" -gt '0' ] && {
  echo "${IAM}: need root privileges, exiting." >&2
  exit 1
}

# If this script starts without a parameter, it will show the help message and exit
[ -n "${1}" ] || { help >&2; exit 1; }


# The option declarations.
unset PRM_POSTGRES PRM_STORAGE PRM_CONFIG PRM_DELETE
while [ "${#}" -gt '0' ]; do case "${1}" in
  '-a'|'--all') PRM_ALL_CONTAINERS='true';;
  '-p'|'--postgres') PRM_POSTGRES='true';;
  '-s'|'--storage') PRM_STORAGE='true';;
  '-c'|'--config') PRM_CONFIG='true';;
  '-d'|'--delete') PRM_DELETE='true';;
  '-h'|'--help') help >&2; exit;;
  '--') shift; break;;
  -*) echo "${IAM}: don't know about '${1}'." >&2; help >&2; exit 1;;
  *) break;;
esac; shift; done


# Start main function (if an parameter is given)
main "${@}"

