#!/bin/bash

set -e

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

# function for error catching
catch_error(){
  echo -e "\n${ERROR} ${@}"
  exit 1
}

# trap for ctrl+c
trap 'catch_error User exited' SIGINT

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

# verify docker daemon is accessible
if ! $(docker info > /dev/null 2>&1)
then
  catch_error "Docker daemon not accessible. Is the Docker socket shared into the container as a volume?"
fi

# perform a docker login to the v1 registry
echo -e "${NOTICE} Please login for ${V1_REGISTRY}:"
LOGIN_SUCCESS="false"
# keep retrying docker login until successful
while [ "$LOGIN_SUCCESS" = "false" ]
do
  docker login ${V1_REGISTRY} && LOGIN_SUCCESS="true"
done

# decode username/password for v1 registry auth to query API
V1_AUTH="$(cat ~/.dockercfg | jq -r '."'${V1_REGISTRY}'".auth' | base64 --decode)"

# get list of images in v1 registry
echo -e "\n${INFO} Getting a list of images from ${V1_REGISTRY}"
IMAGE_LIST="$(curl -s https://${V1_AUTH}@${V1_REGISTRY}/v1/search?q= | jq -r '.results | .[] | .name')"

# loop through all images in v1 registry to get tags for each
for i in ${IMAGE_LIST}
do
  # get list of tags for image i
  IMAGE_TAGS=$(curl -s https://${V1_AUTH}@${V1_REGISTRY}/v1/repositories/${i}/tags | jq -r 'keys | .[]')

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
echo -e "${OK} Successfully retrieved list of Docker images from ${V1_REGISTRY}"

# show list of images from the v1 registry
echo -e "\n${INFO} Full list of images from ${V1_REGISTRY} to be migrated:"
for i in ${FULL_IMAGE_LIST}
do
  echo ${V1_REGISTRY}/${i}
done
echo -e "${OK} End full list of images from ${V1_REGISTRY}"
echo -en "\n${NOTICE} "
read -rsp $"Press any key to begin migration process [ctrl+c to abort]" -n1 key; echo

# pull all images to local system
echo -e "\n${INFO} Pulling all images from ${V1_REGISTRY} to your local system"
for i in ${FULL_IMAGE_LIST}
do
  echo -e "${INFO} Pulling ${V1_REGISTRY}/${i}"
  docker pull ${V1_REGISTRY}/${i} || catch_error "Failed to pull ${V1_REGISTRY}/${i}"
  echo -e "${OK} Successfully pulled ${V1_REGISTRY}/${i}\n"
done
echo -e "${OK} Successully pulled all images from ${V1_REGISTRY} to your local system"

# check to see if v1 and v2 registry share the same DNS name
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
    docker tag -f ${V1_REGISTRY}/${i} ${V2_REGISTRY}/${i} || catch_error "Failed to retag ${V1_REGISTRY}/${i} to ${V2_REGISTRY}/${i}"
    echo -e "${OK} ${V1_REGISTRY}/${i} > ${V2_REGISTRY}/${i}"
  done
  echo -e "${OK} Successfully retagged all images"
fi

# verify V2_REGISTRY is reporting as a v2 registry
V2_READY="false"
while [ "${V2_READY}" = "false" ]
do
  # check to see if V2_REGISTRY is returning the proper api version string
  if $(curl -Is https://${V2_REGISTRY}/v2/ | grep ^'Docker-Distribution-Api-Version: registry/2' > /dev/null 2>&1)
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

# perform a docker login to the v2 registry
echo -e "\n${NOTICE} Please login for ${V2_REGISTRY}:"
LOGIN_SUCCESS="false"
# keep retrying docker login until successful
while [ "$LOGIN_SUCCESS" = "false" ]
do
  docker login ${V2_REGISTRY} && LOGIN_SUCCESS="true"
done

# push images to v2 registry
echo -e "\n${INFO} Pushing all images to ${V2_REGISTRY}"
for i in ${FULL_IMAGE_LIST}
do
  echo -e "${INFO} Pushing ${V2_REGISTRY}/${i}"
  docker push ${V2_REGISTRY}/${i} || catch_error "Failed to push ${V2_REGISTRY}/${i}"
  echo -e "${OK} Successfully pushed ${V2_REGISTRY}/${i}\n"
done
echo -e "${OK} Successfully pushed all images to ${V2_REGISTRY}"

# cleanup images from local docker engine
echo -e "\n${INFO} Cleaning up images from local Docker engine"
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

echo -e "\n${OK} Migration from v1 to v2 complete!"
