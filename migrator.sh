#!/bin/bash

set -e

# sets colors for use in output
GREEN='\e[32m'
YELLOW='\e[0;33m'
RED='\e[31m'
BOLD='\e[1m'
CLEAR='\e[0m'

# pre-configure ok, warning, and error output
OK="[${GREEN}OK${CLEAR}]"
NOTICE="[${YELLOW}NOTICE${CLEAR}]"
ERROR="[${RED}ERROR${CLEAR}]"

# function for error catching
catch_error(){
  echo -e "\n${ERROR} ${@}"
  exit 1
}

# verify v1 registry variable has been passed
if [ -z "${V1_REGISTRY_URL}" ]
then
  echo -e "${ERROR} ${BOLD}V1_REGISTRY_URL${CLEAR} environment variable required"
  exit 1
fi

# verify v2 registry variable has been passed
if [ -z "${V2_REGISTRY_URL}" ]
then
  echo -e "${ERROR} ${BOLD}V2_REGISTRY_URL${CLEAR} environment variable required"
  exit 1
fi

# verify docker daemon is accessible
if ! $(docker info > /dev/null 2>&1)
then
  echo -e "${ERROR} Docker daemon not accessible. Is the Docker socket shared into the container as a volume?"
  exit 1
fi

# perform a docker login to the v1 registry
echo "Please login for ${V1_REGISTRY_URL}:"
docker login ${V1_REGISTRY_URL} || catch_error "Failed to login to ${V1_REGISTRY_URL}"

# decode username/password for v1 registry auth to query API
V1_AUTH="$(cat ~/.dockercfg | jq -r '."'${V1_REGISTRY_URL}'".auth' | base64 --decode)"

# get list of images in v1 registry
echo -e "\nGetting a list of images from ${V1_REGISTRY_URL}..."
IMAGE_LIST="$(curl -s https://${V1_AUTH}@${V1_REGISTRY_URL}/v1/search?q= | jq -r '.results | .[] | .name')"

# loop through all images in v1 registry to get tags for each
for i in ${IMAGE_LIST}
do
  # get list of tags for image i
  IMAGE_TAGS=$(curl -s https://${V1_AUTH}@${V1_REGISTRY_URL}/v1/repositories/${i}/tags | jq -r 'keys | .[]')

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
echo -e "${OK} Successfully retrieved list of Docker images from ${V1_REGISTRY_URL}"

# pull all images to local system
echo -e "\nPulling all images from ${V1_REGISTRY_URL} to your local system..."
for i in ${FULL_IMAGE_LIST}
do
  docker pull ${V1_REGISTRY_URL}/${i} || catch_error "Failed to pull ${V1_REGISTRY_URL}/${i}"
  echo
done
echo -e "${OK} Successully pulled all images from ${V1_REGISTRY_URL} to your local system"

# check to see if v1 and v2 registry share the same DNS name
if [ "${V1_REGISTRY_URL}" = "${V2_REGISTRY_URL}" ]
then
  # retagging not needed; re-using same DNS name for v2 registry
  echo -e "${OK} Skipping re-tagging; same URL used for v1 and v2\n"
  # notify user to swap out their registry now
  echo -en "${NOTICE} "
  read -rsp $'Swap v1 and v2 registries and then press any key to continue...\n' -n1 key
else
  # re-tag images; different DNS name used for v2 registry
  echo -e "\nRetagging all images from '${V1_REGISTRY_URL}' to '${V2_REGISTRY_URL}'..."
  for i in ${FULL_IMAGE_LIST}
  do
    docker tag -f ${V1_REGISTRY_URL}/${i} ${V2_REGISTRY_URL}/${i} || catch_error "Failed to retag ${V1_REGISTRY_URL}/${i} to ${V2_REGISTRY_URL}/${i}"
    echo -e "${OK} ${V1_REGISTRY_URL}/${i} > ${V2_REGISTRY_URL}/${i}"
  done
  echo -e "${OK} Successfully retagged all images"
fi

# verify V2_REGISTRY_URL is reporting as a v2 registry
if $(curl -Is https://${V2_REGISTRY_URL}/v2/ | grep ^'Docker-Distribution-Api-Version: registry/2.0' > /dev/null 2>&1)
then
  echo -e "\n${OK} Verified v2 registry (${V2_REGISTRY_URL}) is available"
else
  echo -e "\n${ERROR} v2 registry (${V2_REGISTRY_URL}) is not available"
  exit 1
fi

# perform a docker login to the v2 registry
echo -e "\nPlease login for ${V2_REGISTRY_URL}:"
docker login ${V2_REGISTRY_URL} || catch_error "Failed to login to ${V2_REGISTRY_URL}"

# push images to v2 registry
echo -e "\nPushing all images to ${V2_REGISTRY_URL}..."
for i in ${FULL_IMAGE_LIST}
do
  docker push ${V2_REGISTRY_URL}/${i} || catch_error "Failed to push ${V2_REGISTRY_URL}/${i}"
  echo
done
echo -e "${OK} Successfully pushed all images to ${V2_REGISTRY_URL}"

# cleanup images from local docker engine
echo -e "\nCleaning up images from local Docker engine..."
if [ "${V1_REGISTRY_URL}" = "${V2_REGISTRY_URL}" ]
then
  for i in ${FULL_IMAGE_LIST}
  do
    # remove docker image/tags; allow failures here (in case image is actually in use)
    docker rmi ${V1_REGISTRY_URL}/${i} || true
  done
else
  for i in ${FULL_IMAGE_LIST}
  do
    # remove docker image/tags; allow failures here (in case image is actually in use)
    docker rmi ${V1_REGISTRY_URL}/${i} || true
    docker rmi ${V2_REGISTRY_URL}/${i} || true
  done
fi
echo -e "${OK} Successfully cleaned up images from local Docker engine"

echo -e "\n${OK} Migration from v1 to v2 complete!"
