#!/usr/bin/env bash
set -e

# -- Environment --------------------------------------------------------------
CLI="aws ec2"                       # Prefix for 
DRY_RUN_FLAG="--dry-run"            # Enables dry run, otherwise keep it empty.

AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""

CURRENT_REGION="us-east-1"          # Default region
SECURITY_GROUP_NAME="dummy-name"    # Default security group name

SSH_HOME="${HOME}/.ssh"
KEY_PAIR_NAME="dummy-name"          # Acts as default name when importing a key

RED='\033[0;31m'                    # Red
GREEN='\033[0;32m'                  # Green
YELLOW='\033[0;33m'                 # Yellow
NC='\033[0m'                        # No Color

# -- Functions -----------------------------------------------------------------

function LOG() { # 1:MESSAGE, 2:COLOR (defaults to red)
  local COLOR=${2:-$RED}; echo -e "${COLOR}${1}${NC}"
}

function LOG_AND_EXIT() {
  LOG "$1" "$2" && exit 1
}

function READ_INPUT_IF_UNSET() { # 1:ENV_VAR, 2:MESSAGE, 3:MESSAGE_COLOR
  if [ -z "$1" ]; then
    read -p "$(LOG "$2" "$3")" INPUT
    echo "$INPUT"
  else
    echo "$1"
  fi
}

function CHECK_BINARY_OR_EXIT() { # 1:ARRAY_OF_BINARIES
  local BINARIES=("$@")
  for BINARY in "${BINARIES[@]}"
  do
    test $(which $BINARY) || LOG_AND_EXIT "[-] Required '$BINARY' is missing!"
  done
}

function PROMPT() {
  while true; do
    read -p "${1}" yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) LOG "[!] Please answer yes or no." "${YELLOW}";;
    esac
  done
}

function aws.describe-regions() {
  ${CLI} describe-regions --region ${CURRENT_REGION}\
                          --query "Regions[*].[RegionName]"\
                          --output text
}

function change-region() {
  export CURRENT_REGION=$(aws.describe-regions\
    | tr " " "\n"\
    | fzf --no-multi --cycle --border --height 20)

  LOG "[+] Changing region..." "${GREEN}"
  LOG "[#] Current region: ${CURRENT_REGION}" "${RED}"
}

function aws.describe-local-instances() {
  ${CLI} describe-instances --region ${1}\
    | jq '.Reservations[].Instances[] | "\(.Placement.AvailabilityZone) | \(.InstanceId): \(.State.Name) [IP: \(.PublicIpAddress)]"'
}

function aws.describe-global-instances() {
  REGIONS=`aws.describe-regions`
  for REGION in ${REGIONS}
  do
    aws.describe-local-instances "${REGION}"
  done
}

function aws.print-instance-types() {
  ${CLI} describe-instance-types\
    --region ${CURRENT_REGION}\
    --filters Name=current-generation,Values=true\
    --filters Name=processor-info.supported-architecture,Values=x86_64,amd64\
    | jq '.InstanceTypes[] | "\(.InstanceType) [memory_in_mib: \(.MemoryInfo.SizeInMiB)] [vcpus: \(.VCpuInfo.DefaultVCpus)], [disk_in_gb: \(.InstanceStorageInfo.TotalSizeInGB)]"'\
    | sort
}

function aws.get-ubuntu-ami() {
  ${CLI} describe-images\
    --region ${CURRENT_REGION}\
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64*"\
    --query "sort_by(Images, &CreationDate)[-1:].[Name, ImageId]"\
    --output text\
    | xargs
}

function aws.describe-key-pairs() {
  ${CLI} describe-key-pairs\
    --region ${CURRENT_REGION}\
    | jq '.KeyPairs[] | "\(.KeyName) [\(.KeyType)]"'
}

function aws.import-key-pair() {
  ${CLI} import-key-pair\
    ${DRY_RUN_FLAG}\
    --key-name ${1}\
    --public-key-material fileb://${2}\
    --region ${CURRENT_REGION}
}

function pick-key-and-import() {
  LOG "[+] Importing key from ${1} ..." "${GREEN}"
  export PUBLIC_KEY_PATH=$(ls -d ${1}/*.pub | fzf --no-multi --cycle --border --height 20)

  [ -z PUBLIC_KEY_PATH ] && LOG_AND_EXIT "[-] Did not select a key!"

  read -p "$(LOG "[!] Key-pair name (default> ${KEY_PAIR_NAME}): " "${YELLOW}")" KEY_NAME;

  export KEY_NAME=${KEY_NAME:-$KEY_PAIR_NAME} # If not set, fallback on default
  LOG "[#] Selected key-pair name: ${KEY_NAME}"
  aws.import-key-pair "${KEY_NAME}" "${PUBLIC_KEY_PATH}"
  LOG "[+] Imported: $(aws.describe-key-pairs | grep ${KEY_NAME})" "${GREEN}"
}

function aws.get-default-vpc() {
  ${CLI} describe-vpcs\
    --region ${CURRENT_REGION}\
    | jq '.Vpcs[] | select(.IsDefault==true) | select(.State=="available") | "\(.VpcId)"'\
    | xargs\
    | head -n1
}

function aws.get-security-group-id() {
  ${CLI} describe-security-groups --group-names ${1} --region ${CURRENT_REGION}\
    | jq '.SecurityGroups[0].GroupId'\
    | xargs
}

function aws.create-security-group() {
  # Cheking if security group exits
  if [ ! -z "$(aws.get-security-group-id "${1}")" ]; then
    LOG "[+] Security group '${1}' already exits." "${GREEN}"
  else
    LOG "[+] Creating security group '${1}'..." "${GREEN}"
    PROMPT "`LOG '[!] Do you wish to continue? [y/n] ' ${YELLOW}`"
    ${CLI} create-security-group\
      --region "${CURRENT_REGION}"\
      --group-name "${1}"\
      --description "${1}"\
      --vpc-id "$(aws.get-default-vpc)"
  fi

  export SECURITY_GROUP_ID=$(aws.get-security-group-id "${1}")
  LOG "[+] Security group is '${SECURITY_GROUP_ID}'." "${GREEN}"
}

function aws.is-ssh-allowed() {
  ${CLI} describe-security-group-rules\
    --region ${CURRENT_REGION}\
    --filter "Name=group-id,Values=${1}"\
    --filter "Name=tag:SSH,Values=Allowed"\
    --query "SecurityGroupRules[-1:].[SecurityGroupRuleId]"
}

function aws.authorize-ssh() {
  LOG "[+] Checking if SSH is allowed in security group '${1}'..." "${GREEN}"
  if [ $(aws.is-ssh-allowed "${1}") != "[]" ]; then
    LOG "[+] SSH is already allowed." "${GREEN}"
  else
    LOG "[+] Allowing ingress traffic for SSH @ 22..." "${GREEN}"
    ${CLI} authorize-security-group-ingress\
      --region ${CURRENT_REGION}\
      --group-id "${1}"\
      --tag-specification "ResourceType=security-group-rule,Tags=[{Key=SSH,Value=Allowed}]"\
      --protocol tcp\
      --port 22\
      --cidr 0.0.0.0/0
  fi
}

function aws.run-instances() {
  LOG "[+] Configure your EC2 instance" "${GREEN}"
  LOG "[+] Listing available key-pairs..." "${GREEN}"
  export KEY_NAME=$(aws.describe-key-pairs\
    | fzf --no-multi --cycle --border --height 5\
    | xargs\
    | cut -d ' ' -f1)

  if [ -z "${KEY_NAME}" ]; then
    LOG "[+] No key-pairs found." "${GREEN}"
    pick-key-and-import "${SSH_HOME}"
  fi

  LOG "[#] Using key-pair: ${KEY_NAME}"
  read -p "`LOG '[!] Instance name: ' ${YELLOW}`" INSTANCE_NAME;

  PROMPT "`LOG '[!] 1/4 Do you wish to continue? [y/n] ' ${YELLOW}`"

  LOG "[+] Retrieving latest Ubuntu 20.04 x64 AMI..." "${GREEN}"
  export AMI=`aws.get-ubuntu-ami`
  export AMI_ID=`echo ${AMI} | cut -d ' ' -f2`
  LOG "[#] Selected AMI: ${AMI}"

  PROMPT "`LOG '[!] 2/4 Do you wish to continue? [y/n] ' ${YELLOW}`"

  LOG "[+] Listing instance types..." "${GREEN}"
  export INSTANCE_TYPE=`aws.print-instance-types\
    | fzf --no-multi --cycle --border --height 20\
    | xargs\
    | cut -d ' ' -f1`
  LOG "[#] Selected instance type: ${INSTANCE_TYPE}"

  PROMPT "`LOG '[!] 3/4 Do you wish to continue? [y/n] ' ${YELLOW}`"

  aws.create-security-group "${SECURITY_GROUP_NAME}"
  aws.authorize-ssh "${SECURITY_GROUP_ID}"

  PROMPT "`LOG '[!] 4/4 Do you wish to continue? [y/n] ' ${YELLOW}`"

  ${CLI} run-instances ${DRY_RUN_FLAG}\
    --region ${CURRENT_REGION}\
    --image-id ${AMI_ID}\
    --count 1\
    --instance-type ${INSTANCE_TYPE}\
    --key-name ${KEY_NAME}\
    --security-group-ids ${SECURITY_GROUP_ID}\
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]"

  exit
}

# -- Workflow -----------------------------------------------------------------

# Checking if required tools are available
REQUIREMENTS=("aws" "jq" "fzf"); CHECK_BINARY_OR_EXIT "${REQUIREMENTS[@]}"

# Ask for AWS credentials if not available
AWS_ACCESS_KEY_ID=$(READ_INPUT_IF_UNSET "${AWS_ACCESS_KEY_ID}" "[!] Please provide aws-access-key-id > " "${YELLOW}")
AWS_SECRET_ACCESS_KEY=$(READ_INPUT_IF_UNSET "${AWS_SECRET_ACCESS_KEY}" "[!] Please provide aws-secret-access-key > " "${YELLOW}")
# Check if credentials are set
#if [ -z ${AWS_ACCESS_KEY_ID} ] || [ -z ${AWS_SECRET_ACCESS_KEY} ]; then LOG_AND_EXIT "[-] Invalid credentials! Exiting..."; fi

LOG "[#] Current region: ${CURRENT_REGION}"

PS3=$(LOG "[!] Please enter your choice: " "${YELLOW}")

OPTIONS=("Change current region"
         "List global EC2 instances"
         "List local EC2 instances"
         "Import key-pair"
         "Create EC2 instance"
         "Quit")

select OPT in "${OPTIONS[@]}"
do
    case ${OPT} in
        "Change current region")
            change-region
            ;;
        "List global EC2 instances")
            LOG "[+] Listing global instances..." "${GREEN}"
            aws.describe-global-instances
            ;;
        "List local EC2 instances")
            LOG "[+] Listing local instances..." "${GREEN}"
            aws.describe-local-instances "${CURRENT_REGION}"
            ;;
        "Import key-pair")
            pick-key-and-import "${SSH_HOME}"
            ;;
        "Create EC2 instance")
            aws.run-instances
            ;;
        "Quit")
            break
            ;;
        *) echo "Invalid option: ${REPLY}";;
    esac
done
