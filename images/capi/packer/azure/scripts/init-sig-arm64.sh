#!/bin/bash

[[ -n ${DEBUG:-} ]] && set -o xtrace

tracestate="$(shopt -po xtrace)"
set +o xtrace
az login --service-principal -u ${AZURE_CLIENT_ID} -p ${AZURE_CLIENT_SECRET} --tenant ${AZURE_TENANT_ID} >/dev/null 2>&1
az account set -s ${AZURE_SUBSCRIPTION_ID} >/dev/null 2>&1
eval "$tracestate"

export RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-cluster-api-images}"
export AZURE_LOCATION="${AZURE_LOCATION:-southcentralus}"
if ! az group show -n ${RESOURCE_GROUP_NAME} -o none 2>/dev/null; then
  az group create -n ${RESOURCE_GROUP_NAME} -l ${AZURE_LOCATION} --tags ${TAGS:-}
fi
CREATE_TIME="$(date +%s)"
RANDOM_SUFFIX="$(head /dev/urandom | LC_ALL=C tr -dc a-z | head -c 4 ; echo '')"
export GALLERY_NAME="${GALLERY_NAME:-ClusterAPI${CREATE_TIME}${RANDOM_SUFFIX}}"

# Hack to set only build_resource_group_name or location, a better solution is welcome
# https://developer.hashicorp.com/packer/plugins/builders/azure/arm#build_resource_group_name
PACKER_FILE_PATH=packer/azure/
TMP_PACKER_FILE=$PACKER_FILE_PATH"packer.json.tmp"
PACKER_FILE=$PACKER_FILE_PATH"packer.json"
if [ ${BUILD_RESOURCE_GROUP_NAME} ]; then
    if ! az group show -n ${BUILD_RESOURCE_GROUP_NAME} -o none 2>/dev/null; then
        az group create -n ${BUILD_RESOURCE_GROUP_NAME} -l ${AZURE_LOCATION} --tags ${TAGS:-}
    fi
    jq '(.builders | map(if .name | contains("sig") then del(.location) + {"build_resource_group_name": "{{user `build_resource_group_name`}}"} else . end)) as $updated | .builders = $updated' $PACKER_FILE  > $TMP_PACKER_FILE
    mv $TMP_PACKER_FILE $PACKER_FILE
fi

packer validate -syntax-only $PACKER_FILE || exit 1

az sig create --resource-group ${RESOURCE_GROUP_NAME} --gallery-name ${GALLERY_NAME}

SECURITY_TYPE_CVM_SUPPORTED_FEATURE="SecurityType=ConfidentialVmSupported"

create_image_definition() {
  az sig image-definition create \
    --resource-group ${RESOURCE_GROUP_NAME} \
    --gallery-name ${GALLERY_NAME} \
    --gallery-image-definition capi-${SIG_SKU:-$1} \
    --publisher ${SIG_PUBLISHER:-capz} \
    --offer ${SIG_OFFER:-capz-demo} \
    --sku ${SIG_SKU:-$2} \
    --hyper-v-generation ${3} \
    --os-type ${4} \
    --features ${5:-''} \
    --architecture Arm64
}

SIG_TARGET=$1

case ${SIG_TARGET} in
  ubuntu-2004-arm64)
    create_image_definition ${SIG_TARGET} "20_04-lts-arm64" "V2" "Linux"
  ;;
  ubuntu-2204-arm64)
    create_image_definition ${SIG_TARGET} "22_04-lts-arm64" "V2" "Linux"
  ;;
  *)
    >&2 echo "Unsupported SIG target: '${SIG_TARGET}'"
    exit 1
  ;;
esac
