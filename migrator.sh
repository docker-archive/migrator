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

  # set default to require curl to perform ssl certificate validation
  USE_INSECURE_CURL=${USE_INSECURE_CURL:-false}
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

  # verify valid insecure curl variable
  if [ "${USE_INSECURE_CURL}" != "true" ] && [ "${USE_INSECURE_CURL}" != "false" ]
  then
    catch_error "${BOLD}USE_INSECURE_CURL${CLEAR} environment variable (${USE_INSECURE_CURL}) invalid; must be either ${BOLD}true${CLEAR} or ${BOLD}false${CLEAR}"
  else
    # set INSECURE_CURL environment variable to appropriate value
    [ ${USE_INSECURE_CURL} == "true" ] && INSECURE_CURL="-k" || INSECURE_CURL=""
  fi

  # verify docker daemon is accessible
  if ! $(docker info > /dev/null 2>&1)
  then
    catch_error "Docker daemon not accessible. Is the Docker socket shared into the container as a volume?"
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
  [ ${1} == "docker.io" ] && REGISTRY="" || REGISTRY="${1}"
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
    AUTH_CREDS="$(cat ~/.dockercfg | jq -r '."https://index.docker.io/v1/".auth' | base64 --decode)"

    # decode individual username and password
    DOCKER_HUB_USERNAME=$(echo ${AUTH_CREDS} | awk -F ':' '{print $1}')
    DOCKER_HUB_PASSWORD=$(echo ${AUTH_CREDS} | awk -F ':' '{print $2}')
  else
    # decode username and password as a pair
    AUTH_CREDS="$(cat ~/.dockercfg | jq -r '."'${1}'".auth' | base64 --decode)"
  fi
}

# query the source registry for a list of all images
query_source_images() {
  echo -e "\n${INFO} Getting a list of images from ${V1_REGISTRY}"
  # check to see if migrating from docker hub or a v1 registry
  if [ "${DOCKER_HUB}" = "true" ]
  then
    # check to see if DOCKER_HUB_ORG has been specified
    if [ -z "${DOCKER_HUB_ORG}" ]
    then
      # set NAMESPACE to DOCKER_HUB_USERNAME
      NAMESPACE="${DOCKER_HUB_USERNAME}"
    else
      # set NAMESPACE to DOCKER_HUB_ORG
      NAMESPACE="${DOCKER_HUB_ORG}"
    fi

    # get token to be able to talk to Docker Hub
    TOKEN=$(curl ${INSECURE_CURL} -sf -H "Content-Type: application/json" -X POST -d '{"username": "'${DOCKER_HUB_USERNAME}'", "password": "'${DOCKER_HUB_PASSWORD}'"}' https://hub.docker.com/v2/users/login/ | jq -r .token) || catch_error "curl => API failure"

    # get list of namespaces accessible by user
    NAMESPACES=$(curl -sf -H "Authorization: JWT ${TOKEN}" https://hub.docker.com/v2/repositories/namespaces/ | jq -r '.namespaces|.[]') || catch_error "curl => API failure"

    # verify NAMESPACE is in NAMESPACES to ensure proper access; abort if incorrect access
    if ! echo ${NAMESPACES} | grep -w ${NAMESPACE} > /dev/null 2>&1
    then
      catch_error "The Docker Hub user ${BOLD}${DOCKER_HUB_USERNAME}${CLEAR} does not have permission to access ${BOLD}${NAMESPACE}${CLEAR}; aborting"
    fi

    # check to see if a filter pattern was provided
    if [ -z "${V1_REPO_FILTER}" ]
    then
      # no filter pattern was defined, get all repos
      REPO_LIST=$(curl ${INSECURE_CURL} -sf -H "Authorization: JWT ${TOKEN}" https://hub.docker.com/v2/repositories/${NAMESPACE}/?page_size=100000 | jq -r '.results|.[]|.name') || catch_error "curl => API failure"
    else
      # filter pattern defined, use grep to match repos w/regex capabilites
      REPO_LIST=$(curl ${INSECURE_CURL} -sf -H "Authorization: JWT ${TOKEN}" https://hub.docker.com/v2/repositories/${NAMESPACE}/?page_size=100000 | jq -r '.results|.[]|.name' | grep ${V1_REPO_FILTER} || true) || catch_error "curl => API failure"
    fi

    # build a list of all images & tags
    for i in ${REPO_LIST}
    do
      # get tags for repo
      IMAGE_TAGS=$(curl ${INSECURE_CURL} -sf -H "Authorization: JWT ${TOKEN}" https://hub.docker.com/v2/repositories/${NAMESPACE}/${i}/tags/?page_size=100000 | jq -r '.results|.[]|.name') || catch_error "curl => API failure"

      # build a list of images from tags
      for j in ${IMAGE_TAGS}
      do
        # add each tag to list
        FULL_IMAGE_LIST="${FULL_IMAGE_LIST} ${NAMESPACE}/${i}:${j}"
      done
    done
  else
    # check to see if a filter pattern was provided
    if [ -z "${V1_REPO_FILTER}" ]
    then
      # no filter pattern was defined, get all repos
      REPO_LIST=$(curl ${INSECURE_CURL} -sf https://${AUTH_CREDS}@${V1_REGISTRY}/v1/search?q= | jq -r '.results | .[] | .name') || catch_error "curl => API failure"
    else
      # filter pattern defined, use grep to match repos w/regex capabilites
      REPO_LIST=$(curl ${INSECURE_CURL} -sf https://${AUTH_CREDS}@${V1_REGISTRY}/v1/search?q= | jq -r '.results | .[] | .name' | grep ${V1_REPO_FILTER} || true) || catch_error "curl => API failure"
    fi

    # loop through all repos in v1 registry to get tags for each
    for i in ${REPO_LIST}
    do
      # get list of tags for image i
      IMAGE_TAGS=$(curl ${INSECURE_CURL} -sf https://${AUTH_CREDS}@${V1_REGISTRY}/v1/repositories/${i}/tags | jq -r 'keys | .[]') || catch_error "curl => API failure"

      # loop through tags to create list of full image names w/tags
      for j in ${IMAGE_TAGS}
      do
        # check if an image is a 'library' image without a namespace
        if [ ${i:0:8} = "library/" ]
        then
          # cut off 'library/' from beginning of image
          i="${i:8}"
        fi
        # add image to list
        FULL_IMAGE_LIST="${FULL_IMAGE_LIST} ${i}:${j}"
      done
    done
  fi
  echo -e "${OK} Successfully retrieved list of Docker images from ${V1_REGISTRY}"
}

# show list of images from docker hub or the v1 registry
show_source_image_list() {
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

  # check the action and act accordingly
  case ${ACTION} in
    push)
      # push image
      echo -e "${INFO} Pushing ${IMAGE}"
      (docker push ${IMAGE} && echo -e "${OK} Successfully ${ACTION}ed ${IMAGE}\n") || catch_push_pull_error "push" "${IMAGE}"
      ;;
    pull)
      # pull image
      echo -e "${INFO} Pulling ${IMAGE}"
      (docker pull ${IMAGE} && echo -e "${OK} Successfully ${ACTION}ed ${IMAGE}\n") || catch_push_pull_error "pull" "${IMAGE}"
      ;;
  esac
}

# retag image
retag_image() {
  # get source and destination image names passed
  SOURCE_IMAGE="${1}"
  DESTINATION_IMAGE="${2}"

  # retag image
  (docker tag -f ${SOURCE_IMAGE} ${DESTINATION_IMAGE} && echo -e "${OK} ${V1_REGISTRY}/${i} > ${V2_REGISTRY}/${i}") || catch_retag_error "${SOURCE_IMAGE}" "${DESTINATION_IMAGE}"
}

# pull all images to local system
pull_images_from_source() {
  echo -e "\n${INFO} Pulling all images from ${V1_REGISTRY} to your local system"
  for i in ${FULL_IMAGE_LIST}
  do
    push_pull_image "pull" "${V1_REGISTRY}/${i}"
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
    echo -e "\n${INFO} Retagging all images from '${V1_REGISTRY}' to '${V2_REGISTRY}'"
    for i in ${FULL_IMAGE_LIST}
    do
      retag_image "${V1_REGISTRY}/${i}" "${V2_REGISTRY}/${i}"
    done
    echo -e "${OK} Successfully retagged all images"
  fi
}

# verify V2_REGISTRY is reporting as a v2 registry
verify_v2_ready() {
  V2_READY="false"
  while [ "${V2_READY}" = "false" ]
  do
    # check to see if V2_REGISTRY is returning the proper api version string
    if $(curl ${INSECURE_CURL} -Is https://${V2_REGISTRY}/v2/ | grep ^'Docker-Distribution-Api-Version: registry/2' > /dev/null 2>&1)
    then
      # api version indicates v2; sets value to exit loop
      V2_READY="true"
    else
      # api version either not returned or not showing proper version; will continue in loop
      echo -e "\n${ERROR} v2 registry (${V2_REGISTRY}) is not available"
      echo -en "${NOTICE} "
      read -rsp $'Verify v2 registry is functioning as expected; press any key to continue to retry [ctrl+c to abort]\n' -n1 key
    fi
  done
  # v2 registry verified as available
  echo -e "\n${OK} Verified v2 registry (${V2_REGISTRY}) is available"
}

# push images to v2 registry
push_images_to_v2() {
  echo -e "\n${INFO} Pushing all images to ${V2_REGISTRY}"
  for i in ${FULL_IMAGE_LIST}
  do
    push_pull_image "push" "${V2_REGISTRY}/${i}"
  done
  echo -e "${OK} Successfully pushed all images to ${V2_REGISTRY}"
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
      docker rmi ${V1_REGISTRY}/${i} || true
    done
  else
    for i in ${FULL_IMAGE_LIST}
    do
      # remove docker image/tags; allow failures here (in case image is actually in use)
      docker rmi ${V1_REGISTRY}/${i} || true
      docker rmi ${V2_REGISTRY}/${i} || true
    done
  fi
  echo -e "${OK} Successfully cleaned up images from local Docker engine"
}

# migration complete
migration_complete() {
  if [ "${DOCKER_HUB}" = "true" ]
  then
    echo -e "\n${OK} Migration from Docker Hub to v2 complete!"
  else
    echo -e "\n${OK} Migration from v1 to v2 complete!"
  fi
}

# main function
main() {
  initialize_migrator
  verify_ready
  # check to see if NO_LOGIN is set
  if [ "${NO_LOGIN}" != "true" ]; then
    docker_login ${V1_REGISTRY} ${V1_USERNAME} ${V1_PASSWORD} ${V1_EMAIL}
    decode_auth ${V1_REGISTRY}
  fi
  query_source_images
  show_source_image_list
  pull_images_from_source
  check_registry_swap_or_retag
  verify_v2_ready
  # check to see if NO_LOGIN is set
  if [ "${NO_LOGIN}" != "true" ]; then
    docker_login ${V2_REGISTRY} ${V2_USERNAME} ${V2_PASSWORD} ${V2_EMAIL}
  fi
  push_images_to_v2
  cleanup_local_engine
  migration_complete
}

main "$@"
