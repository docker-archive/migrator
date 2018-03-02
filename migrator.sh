#!/bin/bash

set -o pipefail

# initialization
initialize_migrator() {
  # sets colors for use in output
  GREEN='\e[32m'
  BLUE='\e[34m'
  YELLOW='\e[0;33m'
  RED='\e[31m'
  BOLD='\e[1m'
  CLEAR='\e[0m'

  # pre-configure ok, warning, and error output
  OK="[${GREEN}OK${CLEAR}]"
  INFO="[${BLUE}INFO${CLEAR}]"
  NOTICE="[${YELLOW}!!${CLEAR}]"
  ERROR="[${RED}ERROR${CLEAR}]"

  # trap for ctrl+c
  trap 'catch_error User exited' SIGINT

  # trap errors
  trap 'catch_error Non-zero exit code' ERR

  # set default error action to prompt if none provided
  ERROR_ACTION=${ERROR_ACTION:-prompt}

  # set default to prompt user for validation
  USER_PROMPT=${USER_PROMPT:-true}

  # set default to require docker login
  NO_LOGIN=${NO_LOGIN:-false}
  V1_NO_LOGIN=${V1_NO_LOGIN:-false}
  V2_NO_LOGIN=${V2_NO_LOGIN:-false}

  # if NO_LOGIN is true, set both v1 and v2 values to true
  if [ "${NO_LOGIN}" = "true" ]
  then
    V1_NO_LOGIN="true"
    V2_NO_LOGIN="true"
  fi

  # set default to require curl to perform ssl certificate validation
  USE_INSECURE_CURL=${USE_INSECURE_CURL:-false}

  # set default to require https
  USE_HTTP=${USE_HTTP:-false}
  V1_USE_HTTP=${V1_USE_HTTP:-false}
  V2_USE_HTTP=${V2_USE_HTTP:-false}

  # if USE_HTTP is true, set both v1 and v2 values to true
  if [ "${USE_HTTP}" = "true" ]
  then
    V1_USE_HTTP="true"
    V2_USE_HTTP="true"
  fi

  # set default to migrate official namespaces to 'library'
  LIBRARY_NAMESPACE=${LIBRARY_NAMESPACE:-true}

  # set number of images to migrate at once; null means do not migrate incrementally
  MIGRATION_INCREMENT=${MIGRATION_INCREMENT:-}

  # by default not migrate all tags. Set this to true if you want to skip tags that already exist at target
  SKIP_EXISTING_TAGS=${SKIP_EXISTING_TAGS:-false}
}

# verify requirements met for script to execute properly
verify_ready() {
  # verify v1 registry variable has been passed
  if [ -z "${V1_REGISTRY}" ]
  then
    catch_error "${BOLD}V1_REGISTRY${CLEAR} environment variable required"
  fi

  # verify v2 registry variable has been passed
  if [ -z "${V2_REGISTRY}" ]
  then
    catch_error "${BOLD}V2_REGISTRY${CLEAR} environment variable required"
  fi

  # verify valid error action
  if [ "${ERROR_ACTION}" != "prompt" ] && [ "${ERROR_ACTION}" != "retry" ] && [ "${ERROR_ACTION}" != "skip" ] && [ "${ERROR_ACTION}" != "abort" ]
  then
    catch_error "${BOLD}ERROR_ACTION${CLEAR} environment variable (${ERROR_ACTION}) invalid; must be one of the following: ${BOLD}prompt${CLEAR}, ${BOLD}retry${CLEAR}, ${BOLD}skip${CLEAR}, or ${BOLD}abort${CLEAR}"
  fi

  # verify valid user prompt variable
  if [ "${USER_PROMPT}" != "true" ] && [ "${USER_PROMPT}" != "false" ]
  then
    catch_error "${BOLD}USER_PROMPT${CLEAR} environment variable (${USER_PROMPT}) invalid; must be either ${BOLD}true${CLEAR} or ${BOLD}false${CLEAR}"
  fi

  V1_OPTIONS=""
  V2_OPTIONS=""

  # verify valid insecure curl variable
  if [ "${USE_INSECURE_CURL}" != "true" ] && [ "${USE_INSECURE_CURL}" != "false" ]
  then
    catch_error "${BOLD}USE_INSECURE_CURL${CLEAR} environment variable (${USE_INSECURE_CURL}) invalid; must be either ${BOLD}true${CLEAR} or ${BOLD}false${CLEAR}"
  else
    # set INSECURE_CURL environment variable to appropriate value
    if [ "${USE_INSECURE_CURL}" = "true" ]
    then
      V1_OPTIONS="$V1_OPTIONS --insecure"
      V2_OPTIONS="$V2_OPTIONS --insecure"
      INSECURE_CURL="--insecure"
    else
      INSECURE_CURL=""
    fi
  fi

  if [ "${V1_USE_HTTP}" = "true" ]
    then
     V1_PROTO="http"
    else
     V1_PROTO="https"
  fi

  if [ "${V2_USE_HTTP}" = "true" ]
    then
     V2_PROTO="http"
    else
     V2_PROTO="https"
  fi

  # Use client certificates where applicable
  if [ -f "/etc/docker/certs.d/$V1_REGISTRY/client.cert" ]
  then
    V1_OPTIONS="$V1_OPTIONS --cert /etc/docker/certs.d/$V1_REGISTRY/client.cert --key /etc/docker/certs.d/$V1_REGISTRY/client.key"
  fi
  if [ -f "/etc/docker/certs.d/$V2_REGISTRY/client.cert" ]
  then
    V2_OPTIONS="$V2_OPTIONS --cert /etc/docker/certs.d/$V2_REGISTRY/client.cert --key /etc/docker/certs.d/$V2_REGISTRY/client.key"
  fi

  # Use custom CA certificates where applicable
  if [ -f "/etc/docker/certs.d/$V1_REGISTRY/ca.crt" ]
  then
    V1_OPTIONS="$V1_OPTIONS --cacert /etc/docker/certs.d/$V1_REGISTRY/ca.crt"
  fi
  if [ -f "/etc/docker/certs.d/$V2_REGISTRY/ca.crt" ]
  then
    V2_OPTIONS="$V2_OPTIONS --cacert /etc/docker/certs.d/$V2_REGISTRY/ca.crt"
  fi

  # verify docker daemon is accessible
  if ! $(docker info > /dev/null 2>&1)
  then
    catch_error "Docker daemon not accessible. Is the Docker socket shared into the container as a volume?"
  fi

  # verify if v2 repository destination is AWS ECR
  if [[ ${V2_REGISTRY} =~ .*ecr.*amazonaws.com$ ]]
  then
    if [ -f "/root/.aws/credentials" ] || ([ -n "${AWS_ACCESS_KEY_ID}" ] && [ -n "${AWS_SECRET_ACCESS_KEY}" ])
    then
      # AWS REGION must be specified if using ECR
      if [ -z "${AWS_REGION}" ]
      then
  	    catch_error "\$AWS_REGION required"
      fi

      AWS_ECR="true"
      AWS_LOGIN=$(aws ecr get-login --region ${AWS_REGION})
      V2_USERNAME=$(echo ${AWS_LOGIN} | awk -F ' ' '{print $4}')
      V2_PASSWORD=$(echo ${AWS_LOGIN} | awk -F ' ' '{print $6}')
      V2_REGISTRY=$(echo ${AWS_LOGIN} | awk -F 'https://' '{print $2}')
      V2_EMAIL="none"
    else
      catch_error "${BOLD}AWS${CLEAR} credentials required"
    fi
  fi

  # check to see if MIGRATION_INCREMENT has been set
  if [ -n "${MIGRATION_INCREMENT}" ]
  then
    # check to see if MIGRATION_INCREMENT is a positive integer
    if [ ${MIGRATION_INCREMENT} -eq ${MIGRATION_INCREMENT} 2> /dev/null ] && [ ${MIGRATION_INCREMENT} -gt 0 2> /dev/null ]
    then
      # check to see if v1 and v2 are the same
      if [ "${V1_REGISTRY}" = "${V2_REGISTRY}" ]
      then
        catch_error "${BOLD}MIGRATION_INCREMENT${CLEAR} can not be set if source and destination registries are using the same FQDN"
      else
        # set environment variable to indicate migration will be done incrementally
        MIGRATE_IN_INCREMENTS=true
      fi
    else
      catch_error "${BOLD}MIGRATION_INCREMENT${CLEAR} environment variable must be a positive integer"
    fi
  fi

  if [ "${V1_REGISTRY}" = "${V2_REGISTRY}" ] && [ ${SKIP_EXISTING_TAGS} = "true" ]; then
    echo -n "${NOTICE} Partial migration cannot be used when source and destination are using the same FQDN, disabling."
    SKIP_EXISTING_TAGS="false"
  fi
}

# generic error catching
catch_error() {
  echo -e "\n${ERROR} ${@}"
  if [ "${DOCKER_HUB}" = "true" ]
  then
    echo -e "${ERROR} Migration from Docker Hub to v2 failed!"
  else
    echo -e "${ERROR} Migration from v1 to v2 failed!"
  fi
  exit 1
}

# catch push/pull error
catch_push_pull_error() {
  # set environment variables to handle arguments
  ACTION="${1}"
  IMAGE="${2}"
  TEMP_ERROR_ACTION=${3:-${ERROR_ACTION}}

  # perform action based off of error action
  case $TEMP_ERROR_ACTION in
    prompt)
      # prompt user for course of action
      echo -e "${ERROR} Failed to ${ACTION} ${IMAGE}"
      echo -en "\n${NOTICE} "
      read -rp $"Retry, skip, or abort? {r|s|a} " -n1 RESPONSE; echo

      # act based on user response
      case ${RESPONSE} in
        r|R)
          # re-run function with retry
          catch_push_pull_error "${ACTION}" "${IMAGE}" "retry"
          ;;
        s|S)
          # re-run function with skip
          catch_push_pull_error "${ACTION}" "${IMAGE}" "skip"
          ;;
        a|A)
          # re-run function with abort
          catch_push_pull_error "${ACTION}" "${IMAGE}" "abort"
          ;;
        *)
          # invalid user response; re-run function with prompt
          echo -e "\n${ERROR} Invalid response"
          catch_push_pull_error "${ACTION}" "${IMAGE}" "prompt"
          ;;
      esac
      ;;
    retry)
      # run push or pull again
      echo -e "${ERROR} Failed to ${ACTION} ${IMAGE}; retrying\n"
      push_pull_image "${ACTION}" "${IMAGE}"
      ;;
    skip)
      # skip push or pull and proceeed
      echo -e "${ERROR} Failed to ${ACTION} ${IMAGE}; skipping\n"
      ;;
    abort)
      # abort and exit migration
      catch_error "Failed to ${ACTION} ${IMAGE}; aborting"
      ;;
  esac
}

# catch retag error
catch_retag_error() {
  # set environment variables to handle arguments
  SOURCE_IMAGE="${1}"
  DESTINATION_IMAGE="${2}"
  TEMP_ERROR_ACTION=${3:-${ERROR_ACTION}}

  # perform action based off of error action
  case $TEMP_ERROR_ACTION in
    prompt)
      # prompt user for course of action
      echo -e "${ERROR} Failed to retag ${SOURCE_IMAGE} > ${DESTINATION_IMAGE}"
      echo -en "\n${NOTICE} "
      read -rp $"Retry, skip, or abort? {r|s|a} " -n1 RESPONSE; echo

      # act based on user response
      case ${RESPONSE} in
        r|R)
          # re-run function with retry
          catch_retag_error "${SOURCE_IMAGE}" "${DESTINATION_IMAGE}" "retry"
          ;;
        s|S)
          # re-run function with skip
          catch_retag_error "${SOURCE_IMAGE}" "${DESTINATION_IMAGE}" "skip"
          ;;
        a|A)
          # re-run function with abort
          catch_retag_error "${SOURCE_IMAGE}" "${DESTINATION_IMAGE}" "abort"
          ;;
        *)
          # invalid user response; re-run function with prompt
          echo -e "\n${ERROR} Invalid response"
          catch_retag_error "${SOURCE_IMAGE}" "${DESTINATION_IMAGE}" "prompt"
          ;;
      esac
      ;;
    retry)
      # run retag again
      echo -e "${ERROR} Failed to retag ${IMAGE}; retrying\n"
      retag_image "${SOURCE_IMAGE}" "${DESTINATION_IMAGE}"
      ;;
    skip)
      # skip retag and proceed
      echo -e "${ERROR} Failed to retag ${IMAGE}; skipping\n"
      ;;
    abort)
      # abort and exit migration
      catch_error "Failed to retag ${IMAGE}; aborting"
      ;;
  esac
}

# perform a docker login
docker_login() {
  # leave REGISTRY empty if v1 is docker hub (docker.io); else set REGISTRY to v1
  [ "${1}" == "docker.io" ] && REGISTRY="" || REGISTRY="${1}"
  USERNAME="${2}"
  PASSWORD="${3}"
  EMAIL="${4}"

  if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ] && [ -n "${EMAIL}" ]
  then
    # docker login with credentials provided
    docker login --username="${USERNAME}" --password="${PASSWORD}" --email="${EMAIL}" ${REGISTRY} || catch_error "Failed to login using provided credentials"
  else
    # prompt for credentials for docker login
    echo -e "${NOTICE} Please login to ${REGISTRY}:"
    LOGIN_SUCCESS="false"
    # keep retrying docker login until successful
    while [ "$LOGIN_SUCCESS" = "false" ]
    do
      docker login ${REGISTRY} && LOGIN_SUCCESS="true"
    done
  fi
}

# decode username/password for a registry to query the API
decode_auth() {
  # check to see if the v1 is specified as docker hub (docker.io) to see if individual username/password is required
  if [ "${1}" = "docker.io" ]
  then
    # set DOCKER_HUB to true for future use
    DOCKER_HUB="true"

    # decode username and password as a pair
    AUTH_CREDS="$(cat ~/.dockercfg | jq -r '."https://index.docker.io/v1/".auth' | base64 -d)"

    # decode individual username and password
    DOCKER_HUB_USERNAME=$(echo ${AUTH_CREDS} | awk -F ':' '{print $1}')
    DOCKER_HUB_PASSWORD=$(echo ${AUTH_CREDS} | awk -F ':' '{print $2}')
  else
    # decode username and password as a pair
    AUTH_CREDS="$(cat ~/.dockercfg | jq -r '."'${1}'".auth' | base64 -d)"
  fi
}

##
# Get all the tags for a name at the target repository.
# Supports forced pagination on the tags list (as done by ECR and probably others)
#
# If MIGRATE_ALL is set to true, the list will not be queried but always be empty
#
# Usage: query_tags_to_skip <image_name>
# Return: json-list of all tags in the form ["latest", "dev", "123"]. If the request fails, the list will be empty
##
query_tags_to_skip() {
  IMAGE="${1}"

  if [ "${SKIP_EXISTING_TAGS}" = "false" ]; then
    echo "[]"
    return 0
  fi

  if [ "${AWS_ECR}" == "true" ]; then
    TAGS=$(aws ecr list-images --repository-name ${IMAGE} --region ${AWS_REGION} | jq -cM '[.imageIds[].imageTag]')
    echo ${TAGS}
    return 0
  fi

  INNER_AUTH_TRIES=0

  AUTHORIZATION_HEADER="Authorization: Basic $(echo ${V2_USERNAME}:${V2_PASSWORD} | base64)"

  TAGS_URL="${V2_PROTO}://${V2_REGISTRY}/v2/${IMAGE}/tags/list"
  TAGS="[]"

  while [ -n "${TAGS_URL}" ]; do

    TAGS_RESPONSE=$(curl ${INSECURE_CURL} -i -s "${TAGS_URL}" --header "${AUTHORIZATION_HEADER}")

    FIRST=true
    HEADER=false
    BODY=false

    NEXT_PAGE=""
    NEED_AUTH=""

    # read the `curl -i` output which looks like:
    # <Status Line>\r
    # <Headers> = <Header>[...<Header>]
    # -- separating newline --
    # <Body>
    while IFS= read -r line; do
      if [ ${FIRST} = "true" ]; then
        RESPONSE_STATUS=${line}
        FIRST=false
        HEADER=true
        continue
      fi

      if [ ${HEADER} = "true" ]; then
        if [ "$line" = $'\r' ]; then
          HEADER=false
          BODY=true
          continue
        fi

        # match regular expressions case insensitive, headers can have any casing (RFC 2616 Sec 4.2)
        shopt -s nocasematch

        if [[ "$line" =~ $'Link' ]]; then
           NEXT_PAGE="$line"
        fi
        if [[ "$line" =~ $'Www-Authenticate' ]]; then
           NEED_AUTH="$line"
        fi
        RESPONSE_HEADER="$RESPONSE_HEADER\n$line"
      fi

      if [ "${BODY}" = "true" ]; then
        RESPONSE_BODY+="$line"
      fi

    done < <(echo "${TAGS_RESPONSE}")

    if [[ -n ${NEED_AUTH} ]]; then

      if [ ${INNER_AUTH_TRIES} == 1 ]; then
        # prevent infinite loop when authentication cannot succeed
        break
      fi

      REALM_MATCHER="REALM=\"([^\"]*)\""
      SERVICE_MATCHER="SERVICE=\"([^\"]*)\""
      SCOPE_MATCHER="SCOPE=\"([^\"]*)\""
      if [[ ${NEED_AUTH} =~ $REALM_MATCHER ]]; then
        REALM=${BASH_REMATCH[1]}
      fi
      if [[ ${NEED_AUTH} =~ $SERVICE_MATCHER ]]; then
        SERVICE=${BASH_REMATCH[1]}
      fi
      if [[ ${NEED_AUTH} =~ $SCOPE_MATCHER ]]; then
        SCOPE=${BASH_REMATCH[1]}
      fi

      AUTH_URL="${REALM}?service=${SERVICE}&scope=${SCOPE}"
      AUTH_RESPONSE=$(curl ${INSECURE_CURL} -s "${AUTH_URL}" --user "${V2_USERNAME}:${V2_PASSWORD}")
      AUTH_TOKEN=$(echo ${AUTH_RESPONSE} | jq .token | tr -d '"')
      AUTHORIZATION_HEADER="Authorization: Bearer ${AUTH_TOKEN}"
      INNER_AUTH_TRIES=1

      continue
    fi

    if ! [[ "${RESPONSE_STATUS}" =~ "HTTP/"(1(.[10])?|2)" 200".* ]]; then
      # retrieving existing tags failed
      break
    fi

    # bash substring mechanism requires us to save this into an intermediate field
    NEXT_PAGE_LINK_IN_CHEVRONS=$(echo ${NEXT_PAGE} | grep -o '<.*>')
    NEXT_PAGE_LINK=${NEXT_PAGE_LINK_IN_CHEVRONS:1:-1}
    THIS_PAGE_TAGS=$(echo ${RESPONSE_BODY} | jq -cM '[.tags[]]')
    TAGS=$(jq -scM '.[0] as $o1 | .[1] as $o2 | ($o1 + $o2)' < <(echo ${TAGS}; echo ${THIS_PAGE_TAGS}))

    TAGS_URL=${NEXT_PAGE_LINK}
  done

  echo ${TAGS}

}

##
# Check if a json array contains a needle
#
# Usage: json_array_contains <haystack> <needle>
# Return: "true" or "false"
#
# Usage example: json_array_contains '["a", "b", "c"]' "c"
#                => "true"
##
json_array_contains() {
  HAYSTACK="${1}"
  NEEDLE="${2}"

  echo ${HAYSTACK} | jq --arg needle ${NEEDLE} 'any(.[]; . == $needle)'
}

strip_library() {
  # check if an image ($1) is a 'library' image without a namespace and LIBRARY_NAMESPACE is set to false
  if [ "${1:0:8}" = "library/" ] && [ "${LIBRARY_NAMESPACE}" = "false" ]; then
    # cut off 'library/' from beginning of image
    echo "${1:8}"
  else
    echo $1
  fi
}

# Filter tags if a specific tag was given, or they exist in the destination.
filter_tags() {
  # Only add path separator if namespace is set. Dockerhub added username,
  # but it is not required by the V2 api.
  FULL_IMAGE_NAME="${NAMESPACE}${NAMESPACE:+/}${i}:${j}"

  # only append this tag to the list if the tag wasn't pushed before
  if [ "$(json_array_contains ${TAGS_AT_TARGET} ${j})" = "true" ]; then
    echo -e "${INFO} Skipping ${V1_REGISTRY}/${FULL_IMAGE_NAME}"
  else
    # no tag filter
    if [ -z "${V1_TAG_FILTER}" ]; then
      # add each tag to list
      FULL_IMAGE_LIST="${FULL_IMAGE_LIST} ${FULL_IMAGE_NAME}"
    else
      # if tag filter, check for a match
      if [ "$j" == "${V1_TAG_FILTER}" ]; then
        # Match, so add the tag
        FULL_IMAGE_LIST="${FULL_IMAGE_LIST} ${FULL_IMAGE_NAME}"
      else
        echo -e "${INFO} Skipping ${V1_REGISTRY}/${FULL_IMAGE_NAME}"
      fi
    fi
  fi
}

# query the source registry for a list of all images
query_source_images() {
  echo -e "\n${INFO} Getting a list of images from ${V1_REGISTRY}"
  # check to see if migrating from docker hub or a v1 registry
  if [ "${DOCKER_HUB}" = "true" ]
  then
    # get token to be able to talk to Docker Hub
    TOKEN=$(curl ${INSECURE_CURL} -sf -H "Content-Type: application/json" -X POST -d '{"username": "'${DOCKER_HUB_USERNAME}'", "password": "'${DOCKER_HUB_PASSWORD}'"}' https://hub.docker.com/v2/users/login/ | jq -r .token) || catch_error "curl => API failure getting token"

    # check to see if DOCKER_HUB_ORG has been specified
    if [ -z "${DOCKER_HUB_ORG}" ]
    then
      # set NAMESPACE to DOCKER_HUB_USERNAME
      NAMESPACE="${DOCKER_HUB_USERNAME}"
    else
      # set NAMESPACE to DOCKER_HUB_ORG
      NAMESPACE="${DOCKER_HUB_ORG}"

      # get list of namespaces accessible by user
      NAMESPACES=$(curl -sf -H "Authorization: JWT ${TOKEN}" https://hub.docker.com/v2/user/orgs/ | jq -r '.results|.[].orgname') || catch_error "curl => API failure gettng namespaces"

      # verify NAMESPACE is in NAMESPACES to ensure proper access; abort if incorrect access
      if ! echo ${NAMESPACES} | grep -w ${NAMESPACE} > /dev/null 2>&1
      then
        catch_error "The Docker Hub user ${BOLD}${DOCKER_HUB_USERNAME}${CLEAR} does not have permission to access ${BOLD}${NAMESPACE}${CLEAR}; aborting"
      fi
    fi

    # set page URL to start with
    PAGE_URL="https://hub.docker.com/v2/repositories/${NAMESPACE}/?page=1&page_size=25"

    # no filter pattern was defined, get all repos, looping through each page
    while [ "${PAGE_URL}" != "null" ]
    do
      # get a list of repos on this page
      PAGE_DATA=$(curl ${INSECURE_CURL} -sf -H "Authorization: JWT ${TOKEN}" "${PAGE_URL}") || catch_error "curl => API failure getting repo list"

      # figure out next page URL
      PAGE_URL="$(echo $PAGE_DATA | jq -r .next)"

      # Add repos to the list
      FULL_REPO_LIST="${FULL_REPO_LIST} $(echo ${PAGE_DATA} | jq -r '.results|.[]|.name')"
    done

    # check to see if a filter pattern was provided, create a list of all repositories for the given namespace
    if [ -z "${V1_REPO_FILTER}" ]
    then
      # no filter provided; do no filtering
      REPO_LIST="${FULL_REPO_LIST}"
    else
      # filter provided; build list of what we will and will not migrate
      REPO_LIST="$(echo "$FULL_REPO_LIST" | grep ${V1_REPO_FILTER} || true)"
      FILTERED_REPO_LIST="$(echo "$FULL_REPO_LIST" | grep -v ${V1_REPO_FILTER} || true)"

      for i in ${FILTERED_REPO_LIST}
      do
        echo -e "${INFO} Skipping ${V1_REGISTRY}/${NAMESPACE}/${i} (all tags)"
      done
    fi

    # build a list of all images & tags
    for i in ${REPO_LIST}
    do
      # reset the IMAGE_TAGS variable
      IMAGE_TAGS=""

      # set page URL to start with
      PAGE_URL="https://hub.docker.com/v2/repositories/${NAMESPACE}/${i}/tags/?page=1&page_size=250"

      # retrieve a list of tags at the target repository
      TAGS_AT_TARGET=$(query_tags_to_skip ${NAMESPACE}/${i})

      # loop through each page of tags
      while [ "${PAGE_URL}" != "null" ]
      do
        # get a list of tags on this page
        PAGE_DATA=$(curl ${INSECURE_CURL} -sf -H "Authorization: JWT ${TOKEN}" "${PAGE_URL}") || catch_error "curl => API failure getting tag list"

        # figure out next page URL
        PAGE_URL="$(echo $PAGE_DATA  | jq -r .next)"

        # Add tags to the list
        IMAGE_TAGS="${IMAGE_TAGS} $(echo ${PAGE_DATA} | jq -r '.results|.[]|.name')"
      done

      # build a list of images from tags
      for j in ${IMAGE_TAGS}
      do
        i=$(strip_library $i)
        filter_tags
      done
    done
  else
    # Allow user to provide the full repo list
    if [ -z "${V1_FULL_REPO_LIST}" ]
    then
      # get a list of all repos
      echo -e "${INFO} Grabbing list of repositories from ${V1_REGISTRY}"
      FULL_REPO_LIST=$(curl ${V1_OPTIONS} -sf ${V1_PROTO}://${AUTH_CREDS}@${V1_REGISTRY}/v1/search?q= | jq -r '.results | .[] | .name') || catch_error "curl => API failure getting repo list"
    else
      FULL_REPO_LIST=${V1_FULL_REPO_LIST}
    fi
    # check to see if a filter pattern was provided
    if [ -z "${V1_REPO_FILTER}" ]
    then
      # no filter pattern was defined, get all repos
      REPO_LIST="${FULL_REPO_LIST}"
    else
      # filter pattern defined, use grep to match repos w/regex capabilites
      REPO_LIST=$(echo "${FULL_REPO_LIST}" | grep ${V1_REPO_FILTER} || true)
      # get list of filtered repos
      FILTERED_REPO_LIST="$(echo "${FULL_REPO_LIST}" | grep -v ${V1_REPO_FILTER} || true)"

      for i in ${FILTERED_REPO_LIST}
      do
        echo -e "${INFO} Skipping ${V1_REGISTRY}/${NAMESPACE}/${i} (all tags)"
      done
    fi

    # loop through all repos in v1 registry to get tags for each
    for i in ${REPO_LIST}
    do
      # get list of tags for image i
      if [[ $i != *"%2F"* ]]; then
          echo -e "${INFO} Grabbing tags for ${V1_REGISTRY}/${NAMESPACE}/${i}"
          #echo -e "curl -v ${V1_OPTIONS} -sf ${V1_PROTO}://${AUTH_CREDS}@${V1_REGISTRY}/v1/repositories/${i}/tags"
          IMAGE_TAGS=$(curl ${V1_OPTIONS} -sf ${V1_PROTO}://${AUTH_CREDS}@${V1_REGISTRY}/v1/repositories/${i}/tags | jq -r 'keys | .[]') || catch_error "curl => API failure reading tags"
    
          # retrieve a list of tags at the target repository
          TAGS_AT_TARGET=$(query_tags_to_skip ${i})
          echo -e "${INFO} Found the following existing tags at ${V2_REGISTRY}/${NAMESPACE}/${i}: ${TAGS_AT_TARGET}"
    
          # loop through tags to create list of full image names w/tags
          for j in ${IMAGE_TAGS}
          do
            i=$(strip_library $i)
            filter_tags
          done
      fi
    done
  fi
  echo -e "${OK} Successfully retrieved list of Docker images from ${V1_REGISTRY}"
}

# show list of images from docker hub or the v1 registry
show_source_image_list() {
  # check to see if a filter pattern was provided, create a list of all repositories for the given namespace
  echo -e "\n${INFO} Full list of images from ${V1_REGISTRY} to be migrated:"

  # output list with v1 registry name prefix added
  for i in ${FULL_IMAGE_LIST}
  do
    echo ${V1_REGISTRY}/${i}
  done
  echo -e "${OK} End full list of images from ${V1_REGISTRY}"

  # check to see if user should be prompted
  if ${USER_PROMPT}
  then
    # prompt user to press any key to begin migration
    echo -en "\n${NOTICE} "
    read -rsp $"Press any key to begin migration process [ctrl+c to abort]" -n1 key; echo
  fi
}

# push/pull image
push_pull_image() {
  # get action and image name passed
  ACTION="${1}"
  IMAGE="${2}"

  # check to see if values were provided for migration status
  if [ -n "${3}" ] && [ -n "${4}" ]
  then
    # set migration status variable accordingly
    MIG_STATUS="(${3} of ${4})"
  else
    # set migration status to null
    MIG_STATUS=""
  fi

  # check the action and act accordingly
  case ${ACTION} in
    push)
      # push image
      echo -e "${INFO} Pushing ${IMAGE} ${MIG_STATUS}"
      (docker push ${IMAGE} && echo -e "${OK} Successfully ${ACTION}ed ${IMAGE}\n") || catch_push_pull_error "push" "${IMAGE}" "${3}" "${4}"
      ;;
    pull)
      # pull image
      echo -e "${INFO} Pulling ${IMAGE} ${MIG_STATUS}"
      (docker pull ${IMAGE} && echo -e "${OK} Successfully ${ACTION}ed ${IMAGE}\n") || catch_push_pull_error "pull" "${IMAGE}" "${3}" "${4}"
      ;;
  esac
}

# retag image
retag_image() {
  # get source and destination image names passed
  SOURCE_IMAGE="${1}"
  DESTINATION_IMAGE="${2}"

  # check to see if values were provided for migration status
  if [ -n "${3}" ] && [ -n "${4}" ]
  then
    # set migration status variable accordingly
    MIG_STATUS="(${3} of ${4})"
  else
    # set migration status to null
    MIG_STATUS=""
  fi

  # retag image
  echo -e "${INFO} Retagging ${V1_REGISTRY}/${i} to ${V2_REGISTRY}/${i} ${MIG_STATUS}"
  (docker tag -f ${SOURCE_IMAGE} ${DESTINATION_IMAGE} && echo -e "${OK} Successfully retagged ${V1_REGISTRY}/${i} to ${V2_REGISTRY}/${i}\n") || catch_retag_error "${SOURCE_IMAGE}" "${DESTINATION_IMAGE}" "${3}" "${4}"
}

# remove image
remove_image() {
  # get image name passed
  IMAGE="${1}"

  # remove image
  echo -e "${INFO} Removing ${IMAGE}"
  (docker rmi ${IMAGE} && echo -e "${OK} Successfully removed ${IMAGE}\n") || echo -e "${OK} Failed to remove ${IMAGE}; continuing\n"
}

# pull all images to local system
pull_images_from_source() {
  # initialize variable for counting
  COUNT_PULL=1
  LEN_FULL_IMAGE_LIST=$(count_list ${FULL_IMAGE_LIST})

  echo -e "\n${INFO} Pulling all images from ${V1_REGISTRY} to your local system"
  for i in ${FULL_IMAGE_LIST}
  do
    push_pull_image "pull" "${V1_REGISTRY}/${i}" ${COUNT_PULL} ${LEN_FULL_IMAGE_LIST}
    COUNT_PULL=$[$COUNT_PULL+1]
  done
  echo -e "${OK} Successully pulled all images from ${V1_REGISTRY} to your local system"
}

# check to see if docker hub/v1 and v2 registry share the same DNS name
check_registry_swap_or_retag() {
  if [ "${V1_REGISTRY}" = "${V2_REGISTRY}" ]
  then
    # retagging not needed; re-using same DNS name for v2 registry
    echo -e "${OK} Skipping re-tagging; same URL used for v1 and v2\n"
    # notify user to swtich out their registry now
    echo -en "${NOTICE} "
    read -rsp $'Make the necessary changes to switch your v1 and v2 registries and then press any key to continue\n' -n1 key
  else
    # re-tag images; different DNS name used for v2 registry
    # initialize variable for counting
    COUNT_RETAG=1
    LEN_FULL_IMAGE_LIST=$(count_list ${FULL_IMAGE_LIST})

    echo -e "\n${INFO} Retagging all images from '${V1_REGISTRY}' to '${V2_REGISTRY}'"
    for i in ${FULL_IMAGE_LIST}
    do
      retag_image "${V1_REGISTRY}/${i}" "${V2_REGISTRY}/${i}" ${COUNT_RETAG} ${LEN_FULL_IMAGE_LIST}
      COUNT_RETAG=$[$COUNT_RETAG+1]
    done
    echo -e "${OK} Successfully retagged all images"
  fi
}

# verify V2_REGISTRY is reporting as a v2 registry
verify_v2_ready() {
  V2_READY="false"
  while [ "${V2_READY}" = "false" ]
  do
    # check to see if V2_REGISTRY is returning the expected header (see https://docs.docker.com/registry/spec/api/#api-version-check:00e71df22262087fd8ad820708997657)
    if $(curl ${V2_OPTIONS} -Is ${V2_PROTO}://${V2_REGISTRY}/v2/ | grep ^'Docker-Distribution-Api-Version: registry/2.0' > /dev/null 2>&1)
    then
      # api version indicates v2; sets value to exit loop
      V2_READY="true"
    else
      # check to see if error action set to abort to automatically exit when v2 not available
      if [ "${ERROR_ACTION}" = "abort" ]
      then
        # abort and exit migration
        catch_error "Failed verify v2 registry available; aborting"
      else
        # api version either not returned or not showing proper version; will continue in loop
        echo -e "\n${ERROR} v2 registry (${V2_REGISTRY}) is not available"
        echo -en "${NOTICE} "
        read -rsp $'Verify v2 registry is functioning as expected; press any key to continue to retry [ctrl+c to abort]\n' -n1 key
      fi
    fi
  done
  # v2 registry verified as available
  echo -e "\n${OK} Verified v2 registry (${V2_REGISTRY}) is available"
}

# push images to v2 registry
push_images_to_v2() {
  # if using ECR, create repositories before pushing
  if [ "${AWS_ECR}" == "true" ]; then
    for i in ${REPO_LIST}
    do
      # create ECR repository
      aws ecr create-repository --region ${AWS_REGION} --repository-name ${NAMESPACE}/${i}
    done
  fi

  # initialize variable for counting
  COUNT_PUSH=1
  LEN_FULL_IMAGE_LIST=$(count_list ${FULL_IMAGE_LIST})

  echo -e "\n${INFO} Pushing all images to ${V2_REGISTRY}"
  for i in ${FULL_IMAGE_LIST}
  do
    push_pull_image "push" "${V2_REGISTRY}/${i}" ${COUNT_PUSH} ${LEN_FULL_IMAGE_LIST}
    COUNT_PUSH=$[$COUNT_PUSH+1]
  done
  echo -e "${OK} Successfully pushed all images to ${V2_REGISTRY}"
}

# count number of items in a list
count_list() {
  echo $#;
}

# perform migration incrementally
migrate_in_increments() {
  # initialize variables for increment loops
  COUNT_START="0"
  COUNT_END="${MIGRATION_INCREMENT}"
  COUNT_PULL=1
  COUNT_RETAG=1
  COUNT_PUSH=1
  COUNT_DELETE=1

  # count number of items in FULL_IMAGE_LIST
  LEN_FULL_IMAGE_LIST=$(count_list ${FULL_IMAGE_LIST})

  # convert list to array
  FULL_IMAGE_ARR=($FULL_IMAGE_LIST)

  # migrate incrementally while looping through entire list
  while [ ${COUNT_START} -lt ${LEN_FULL_IMAGE_LIST} ]
  do
    # pull images from v1
    for i in ${FULL_IMAGE_ARR[@]:${COUNT_START}:${COUNT_END}}
    do
      push_pull_image "pull" "${V1_REGISTRY}/${i}" ${COUNT_PULL} ${LEN_FULL_IMAGE_LIST}
      COUNT_PULL=$[$COUNT_PULL+1]
    done

    # retag images from v1 for v2
    for i in ${FULL_IMAGE_ARR[@]:${COUNT_START}:${COUNT_END}}
    do
      retag_image "${V1_REGISTRY}/${i}" "${V2_REGISTRY}/${i}" ${COUNT_RETAG} ${LEN_FULL_IMAGE_LIST}
      COUNT_RETAG=$[$COUNT_RETAG+1]
    done

    # push images to v2
    for i in ${FULL_IMAGE_ARR[@]:${COUNT_START}:${COUNT_END}}
    do
      push_pull_image "push" "${V2_REGISTRY}/${i}" ${COUNT_PUSH} ${LEN_FULL_IMAGE_LIST}
      COUNT_PUSH=$[$COUNT_PUSH+1]
    done

    # delete images locally to free disk space
    for i in ${FULL_IMAGE_ARR[@]:${COUNT_START}:${COUNT_END}}
    do
      remove_image "${V1_REGISTRY}/${i}"
      remove_image "${V2_REGISTRY}/${i}"
    done

    # increment COUNT_START by migration increment value
    COUNT_START=$[$COUNT_START+$MIGRATION_INCREMENT]
  done
}

# cleanup images from local docker engine
cleanup_local_engine() {
  echo -e "\n${INFO} Cleaning up images from local Docker engine"

  # check to see if migrating from docker hub
  # see if re-tagged images exist and remove accordingly
  if [ "${V1_REGISTRY}" = "${V2_REGISTRY}" ]
  then
    for i in ${FULL_IMAGE_LIST}
    do
      # remove docker image/tags; allow failures here (in case image is actually in use)
      remove_image "${V1_REGISTRY}/${i}"
    done
  else
    for i in ${FULL_IMAGE_LIST}
    do
      # remove docker image/tags; allow failures here (in case image is actually in use)
      remove_image "${V1_REGISTRY}/${i}"
      remove_image "${V2_REGISTRY}/${i}"
    done
  fi
  echo -e "${OK} Successfully cleaned up images from local Docker engine"
}

# migration complete
migration_complete() {
  if [ "${DOCKER_HUB}" = "true" ]
  then
    echo -e "${OK} Migration from Docker Hub to v2 complete!"
  else
    echo -e "${OK} Migration from v1 to v2 complete!"
  fi
}

# main function
main() {
  initialize_migrator
  verify_ready
  # check to see if NO_LOGIN is not true
  if [ "${V1_NO_LOGIN}" != "true" ]; then
    docker_login ${V1_REGISTRY} ${V1_USERNAME} ${V1_PASSWORD} ${V1_EMAIL}
    decode_auth ${V1_REGISTRY}
  fi
  query_source_images
  show_source_image_list
  # check to see if MIGRATE_IN_INCREMENTS is true
  if [ "${MIGRATE_IN_INCREMENTS}" = "true" ]; then
    # check to see if V2_NO_LOGIN is true
    if [ "${V2_NO_LOGIN}" != "true" ]; then
      docker_login ${V2_REGISTRY} ${V2_USERNAME} ${V2_PASSWORD} ${V2_EMAIL}
    fi
    # perform migration incrementally
    migrate_in_increments
  else
    # perform migration pulling image images at once
    pull_images_from_source
    check_registry_swap_or_retag
    verify_v2_ready
    # check to see if V2_NO_LOGIN is true
    if [ "${V2_NO_LOGIN}" != "true" ]; then
      docker_login ${V2_REGISTRY} ${V2_USERNAME} ${V2_PASSWORD} ${V2_EMAIL}
    fi
    push_images_to_v2
    cleanup_local_engine
  fi
  migration_complete
}

main "$@"
