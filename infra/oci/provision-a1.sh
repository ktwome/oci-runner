#!/usr/bin/env bash
set -Eeuo pipefail

readonly SHAPE="VM.Standard.A1.Flex"
readonly OCPUS="1"
readonly MEMORY_GB="6"
readonly BOOT_VOLUME_GB="50"
readonly DEFAULT_INSTANCE_NAME="quant-platform"
readonly CLOUD_INIT_FILE="infra/oci/cloud-init.yaml"
readonly MANAGED_BY="github-a1-poller"
readonly LOGICAL_ID="ktwome-osaka-quant-platform"

die() {
  echo "::error::$*" >&2
  exit 1
}

notice() {
  echo "::notice::$*"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required GitHub secret or variable is missing: $name"
}

set_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

for name in \
  OCI_CLI_USER \
  OCI_CLI_TENANCY \
  OCI_CLI_FINGERPRINT \
  OCI_CLI_PRIVATE_KEY \
  OCI_SSH_PUBLIC_KEY \
  OCI_REGION \
  OCI_COMPARTMENT_ID \
  OCI_SUBNET_ID; do
  require_env "$name"
done

[[ -f "$CLOUD_INIT_FILE" ]] || die "Missing cloud-init file: $CLOUD_INIT_FILE"
[[ "$OCI_CLI_USER" == ocid1.user.* ]] || die "OCI_CLI_USER is not a user OCID."
[[ "$OCI_CLI_TENANCY" == ocid1.tenancy.* ]] || die "OCI_CLI_TENANCY is not a tenancy OCID."
[[ "$OCI_COMPARTMENT_ID" == ocid1.compartment.* || "$OCI_COMPARTMENT_ID" == ocid1.tenancy.* ]] \
  || die "OCI_COMPARTMENT_ID is not a compartment or tenancy OCID."
[[ "$OCI_SUBNET_ID" == ocid1.subnet.* ]] || die "OCI_SUBNET_ID is not a subnet OCID."
if [[ -n "${OCI_NSG_ID:-}" ]]; then
  [[ "$OCI_NSG_ID" == ocid1.networksecuritygroup.* ]] || die "OCI_NSG_ID is not an NSG OCID."
fi
[[ "$OCI_CLI_PRIVATE_KEY" == *"BEGIN "*"PRIVATE KEY"* ]] \
  || die "OCI_CLI_PRIVATE_KEY does not look like a PEM private key."
[[ "$OCI_SSH_PUBLIC_KEY" == ssh-* || "$OCI_SSH_PUBLIC_KEY" == ecdsa-* ]] \
  || die "OCI_SSH_PUBLIC_KEY does not look like an OpenSSH public key."

instance_name="${OCI_INSTANCE_NAME:-$DEFAULT_INSTANCE_NAME}"
validate_only="${VALIDATE_ONLY:-false}"
case "$validate_only" in
  true|false) ;;
  *) die "VALIDATE_ONLY must be true or false." ;;
esac

if [[ "$OCI_REGION" == "ap-chuncheon-1" ]]; then
  die "OCI Always Free A1 instances are unavailable in South Korea North (Chuncheon)."
fi

work_dir="$(mktemp -d)"
config_file="$work_dir/config"
private_key_file="$work_dir/oci_api_key.pem"
ssh_public_key_file="$work_dir/instance.pub"
launch_error_file="$work_dir/launch.err"
trap 'rm -rf "$work_dir"' EXIT

umask 077
printf '%s\n' "$OCI_CLI_PRIVATE_KEY" > "$private_key_file"
printf '%s\n' "$OCI_SSH_PUBLIC_KEY" > "$ssh_public_key_file"
cat > "$config_file" <<EOF
[DEFAULT]
user=$OCI_CLI_USER
fingerprint=$OCI_CLI_FINGERPRINT
tenancy=$OCI_CLI_TENANCY
region=$OCI_REGION
key_file=$private_key_file
EOF
chmod 600 "$config_file" "$private_key_file"

oci_cmd() {
  oci --config-file "$config_file" "$@"
}

echo "Validating OCI authentication and Home Region..."
region_subscriptions="$(
  oci_cmd iam region-subscription list \
    --tenancy-id "$OCI_CLI_TENANCY"
)"
home_region="$(
  jq -r '.data[] | select(."is-home-region" == true) | ."region-name"' \
    <<< "$region_subscriptions" | head -n 1
)"
[[ -n "$home_region" ]] || die "Could not determine the tenancy Home Region."
[[ "$OCI_REGION" == "$home_region" ]] \
  || die "OCI_REGION is $OCI_REGION, but Always Free Compute must be created in Home Region $home_region."

echo "Validating subnet..."
subnet_json="$(oci_cmd network subnet get --subnet-id "$OCI_SUBNET_ID")"
subnet_state="$(jq -r '.data."lifecycle-state"' <<< "$subnet_json")"
subnet_ad="$(jq -r '.data."availability-domain" // empty' <<< "$subnet_json")"
subnet_vcn_id="$(jq -r '.data."vcn-id"' <<< "$subnet_json")"
prohibit_public_ip="$(jq -r '.data."prohibit-public-ip-on-vnic"' <<< "$subnet_json")"
[[ "$subnet_state" == "AVAILABLE" ]] || die "Subnet lifecycle state is $subnet_state, not AVAILABLE."
[[ "$prohibit_public_ip" == "false" ]] \
  || die "OCI_SUBNET_ID is private or prohibits public IPs. Select a public subnet for this workflow."

nsg_ids_json=""
if [[ -n "${OCI_NSG_ID:-}" ]]; then
  echo "Validating NSG..."
  nsg_json="$(oci_cmd network nsg get --nsg-id "$OCI_NSG_ID")"
  nsg_state="$(jq -r '.data."lifecycle-state"' <<< "$nsg_json")"
  nsg_vcn_id="$(jq -r '.data."vcn-id"' <<< "$nsg_json")"
  [[ "$nsg_state" == "AVAILABLE" ]] || die "NSG lifecycle state is $nsg_state, not AVAILABLE."
  [[ "$nsg_vcn_id" == "$subnet_vcn_id" ]] \
    || die "OCI_NSG_ID and OCI_SUBNET_ID belong to different VCNs."
  nsg_ids_json="$(jq -cn --arg id "$OCI_NSG_ID" '[$id]')"
else
  notice "OCI_NSG_ID is unset; the instance will rely on the subnet security lists."
fi

echo "Checking for an existing target instance..."
instances_json="$(
  oci_cmd compute instance list \
    --compartment-id "$OCI_COMPARTMENT_ID" \
    --all
)"
jq -e '.data | arrays' <<< "$instances_json" >/dev/null \
  || die "OCI returned an invalid instance-list response."
mapfile -t managed_instances < <(
  jq -c --arg managed_by "$MANAGED_BY" --arg logical_id "$LOGICAL_ID" '
    .data[]
    | select(."lifecycle-state" != "TERMINATED")
    | select(."freeform-tags"."managed-by" == $managed_by)
    | select(."freeform-tags"."logical-id" == $logical_id)
  ' <<< "$instances_json"
)

if [[ "${#managed_instances[@]}" -gt 1 ]]; then
  die "Multiple non-terminated instances have the provisioning logical-id tag. Resolve them manually."
fi

mapfile -t untagged_name_conflicts < <(
  jq -r --arg name "$instance_name" --arg managed_by "$MANAGED_BY" --arg logical_id "$LOGICAL_ID" '
    .data[]
    | select(."lifecycle-state" != "TERMINATED")
    | select(."display-name" == $name)
    | select(
        ."freeform-tags"."managed-by" != $managed_by
        or ."freeform-tags"."logical-id" != $logical_id
      )
    | .id
  ' <<< "$instances_json"
)

if [[ "${#untagged_name_conflicts[@]}" -gt 0 ]]; then
  die "A non-terminated instance named $instance_name exists without this workflow's logical-id tag. Refusing to create a possible duplicate."
fi

existing_id=""
if [[ "${#managed_instances[@]}" -eq 1 ]]; then
  existing_id="$(jq -r '.id' <<< "${managed_instances[0]}")"
  existing_state="$(jq -r '."lifecycle-state"' <<< "${managed_instances[0]}")"
  existing_shape="$(jq -r '.shape' <<< "${managed_instances[0]}")"
  [[ "$existing_shape" == "$SHAPE" ]] \
    || die "The managed logical-id tag belongs to shape $existing_shape, not $SHAPE."
  if [[ "$existing_state" == "TERMINATING" ]]; then
    notice "The managed instance is TERMINATING. A later scheduled run will retry after termination."
    set_output result "terminating"
    set_output provisioned "false"
    exit 0
  fi
fi

if [[ -n "$existing_id" ]]; then
  case "$existing_state" in
    RUNNING)
      notice "A running managed instance already exists."
      set_output result "already_exists"
      set_output provisioned "true"
      exit 0
      ;;
    PROVISIONING|STARTING|MOVING)
      notice "The managed instance is still $existing_state. This run will not create a duplicate."
      set_output result "pending"
      set_output provisioned "false"
      exit 0
      ;;
    *)
      die "The managed instance exists in unexpected state $existing_state. Resolve it manually before polling continues."
      ;;
  esac
fi

image_id="${OCI_IMAGE_ID:-}"
image_name="user-supplied image"
if [[ -z "$image_id" ]]; then
  echo "Selecting the latest available Ubuntu 24.04 image compatible with $SHAPE..."
  images_json="$(
    oci_cmd compute image list \
      --compartment-id "$OCI_COMPARTMENT_ID" \
      --operating-system "Canonical Ubuntu" \
      --operating-system-version "24.04" \
      --shape "$SHAPE" \
      --lifecycle-state AVAILABLE \
      --sort-by TIMECREATED \
      --sort-order DESC \
      --all
  )"
  image_id="$(
    jq -r '
      [
        .data[]
        | select((."display-name" // "") | startswith("Canonical-Ubuntu-24.04"))
        | select((."display-name" // "") | test("Minimal|GPU"; "i") | not)
      ][0].id // empty
    ' <<< "$images_json"
  )"
  image_name="$(
    jq -r --arg id "$image_id" '
      .data[] | select(.id == $id) | ."display-name"
    ' <<< "$images_json"
  )"
  [[ -n "$image_id" ]] \
    || die "No standard Ubuntu 24.04 platform image compatible with $SHAPE was found. Set OCI_IMAGE_ID explicitly."
else
  [[ "$image_id" == ocid1.image.* ]] || die "OCI_IMAGE_ID is not an image OCID."
  image_json="$(oci_cmd compute image get --image-id "$image_id")"
  image_state="$(jq -r '.data."lifecycle-state"' <<< "$image_json")"
  image_name="$(jq -r '.data."display-name"' <<< "$image_json")"
  image_os="$(jq -r '.data."operating-system" // empty' <<< "$image_json")"
  image_os_version="$(jq -r '.data."operating-system-version" // empty' <<< "$image_json")"
  [[ "$image_state" == "AVAILABLE" ]] || die "OCI_IMAGE_ID lifecycle state is $image_state, not AVAILABLE."
  [[ "$image_os" == "Canonical Ubuntu" && "$image_os_version" == 24.04* ]] \
    || die "OCI_IMAGE_ID must be a Canonical Ubuntu 24.04 ARM64 image for this cloud-init configuration."
  if grep -Eqi 'Minimal|GPU' <<< "$image_name"; then
    die "OCI_IMAGE_ID must be a standard non-Minimal, non-GPU Ubuntu 24.04 image."
  fi
fi

oci_cmd compute image-shape-compatibility-entry get \
  --image-id "$image_id" \
  --shape-name "$SHAPE" \
  >/dev/null \
  || die "OCI_IMAGE_ID is not compatible with $SHAPE."

availability_domains_json="$(
  oci_cmd iam availability-domain list \
    --compartment-id "$OCI_CLI_TENANCY"
)"
mapfile -t availability_domains < <(
  jq -r '.data[].name' <<< "$availability_domains_json"
)
[[ "${#availability_domains[@]}" -gt 0 ]] || die "No Availability Domains were returned."

if [[ -n "$subnet_ad" ]]; then
  availability_domains=("$subnet_ad")
fi

echo "Configuration validated:"
echo "  Region: $OCI_REGION"
echo "  Availability Domains: ${availability_domains[*]}"
echo "  Shape: $SHAPE ($OCPUS OCPU, ${MEMORY_GB}GB RAM)"
echo "  Boot volume: ${BOOT_VOLUME_GB}GB"
echo "  Image: $image_name"
echo "  Instance name: $instance_name"

if [[ "$validate_only" == "true" ]]; then
  notice "Validation succeeded. No instance launch was attempted."
  set_output result "validated"
  set_output provisioned "false"
  exit 0
fi

for ad in "${availability_domains[@]}"; do
  echo "Trying $SHAPE in $ad..."
  launch_args=(
    --availability-domain "$ad"
    --compartment-id "$OCI_COMPARTMENT_ID"
    --subnet-id "$OCI_SUBNET_ID"
    --image-id "$image_id"
    --shape "$SHAPE"
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}"
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB"
    --display-name "$instance_name"
    --assign-public-ip true
    --ssh-authorized-keys-file "$ssh_public_key_file"
    --user-data-file "$CLOUD_INIT_FILE"
    --freeform-tags "{\"managed-by\":\"$MANAGED_BY\",\"logical-id\":\"$LOGICAL_ID\",\"AlwaysFreeShape\":\"A1\"}"
  )
  if [[ -n "$nsg_ids_json" ]]; then
    launch_args+=(--nsg-ids "$nsg_ids_json")
  fi
  if launch_json="$(
    oci_cmd --no-retry compute instance launch "${launch_args[@]}" \
      2> "$launch_error_file"
  )"; then
    instance_id="$(jq -r '.data.id // empty' <<< "$launch_json")"
    [[ -n "$instance_id" ]] || die "OCI accepted the launch request but returned no instance OCID."
    notice "Launch accepted in $ad."

    instance_running=false
    if oci_cmd compute instance get \
      --instance-id "$instance_id" \
      --wait-for-state RUNNING \
      --max-wait-seconds 600 \
      >/dev/null; then
      instance_running=true
    else
      notice "The launch was accepted, but the instance did not reach RUNNING within 10 minutes. Checking its actual state."
      if ! instance_json="$(oci_cmd compute instance get --instance-id "$instance_id")"; then
        die "The launch was accepted, but the instance state could not be verified. A later run will find it by tag and will not create a duplicate."
      fi
      instance_state="$(jq -r '.data."lifecycle-state" // empty' <<< "$instance_json")"
      case "$instance_state" in
        RUNNING)
          instance_running=true
          ;;
        PROVISIONING|STARTING|MOVING)
          notice "The managed instance is still $instance_state. A later scheduled run will verify it again."
          set_output result "pending"
          set_output provisioned "false"
          exit 0
          ;;
        TERMINATING|TERMINATED)
          die "The launched instance entered $instance_state before reaching RUNNING. A later scheduled run may retry."
          ;;
        *)
          die "The launched instance is in unexpected state ${instance_state:-unknown}. Resolve it manually."
          ;;
      esac
    fi

    [[ "$instance_running" == "true" ]] \
      || die "Internal error: instance RUNNING state was not confirmed."

    set_output result "created"
    set_output provisioned "true"
    exit 0
  fi

  launch_error="$(< "$launch_error_file")"
  echo "$launch_error" >&2
  if grep -Eqi 'OutOfHostCapacity|Out[[:space:]]+of[[:space:]]+(host[[:space:]]+)?capacity' <<< "$launch_error"; then
    notice "No A1 capacity is currently available in $ad."
    continue
  fi

  die "OCI launch failed for a non-capacity reason; scheduled retries will not hide this error."
done

notice "No A1 capacity is currently available. The next scheduled run will retry."
set_output result "no_capacity"
set_output provisioned "false"
