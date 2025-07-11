#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2174
set -o errexit -o nounset -o pipefail -x
shopt -s nullglob

# Setup defaults.
## RAID Variables
default_create_raid="false"
default_level="${1:-0}"
default_pattern="${2:-/dev/mapper/mpath*}"
default_md_device="/dev/md/0"
default_uhp_devices="4"

## UHP devices variables
default_size="500"
default_vpus="120"

## Single UHP disk attachment variables
default_create_bv="false"
uhp_device="/dev/oracleoci/oraclevdb"
multipath_device="/dev/mapper/mpatha"

## Mounting variables
mount_primary="/mnt/uhp-disk"
mount_extra=(/var/lib/{containerd,kubelet})

## Secondary VNIC variables 
default_secondary_vnic_subnet_id=""
default_secondary_vnic_nic_index=""
default_secondary_vnic_nsg_id=""

# Fetching the instance metadata 
instance_metadata=$(curl -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/instance/)
instance_ocid=$(jq -r .id <<< "$instance_metadata")

# Secondary VNIC setup
secondary_vnic_subnet_id=$(jq --arg default_secondary_vnic_subnet_id "$default_secondary_vnic_subnet_id" -r '.metadata.secondary_vnic_subnet_id // $default_secondary_vnic_subnet_id ' <<< "$instance_metadata")
secondary_nic_index=$(jq --arg default_secondary_vnic_nic_index "$default_secondary_vnic_nic_index" -r '.metadata.secondary_nic_index // $default_secondary_vnic_nic_index ' <<< "$instance_metadata")
secondary_vnic_nsg_id=$(jq --arg default_secondary_vnic_nsg_id "$default_secondary_vnic_nsg_id" -r '.metadata.secondary_vnic_nsg_id // $default_secondary_vnic_nsg_id ' <<< "$instance_metadata")

attached_vnics_metadata=$(curl -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/vnics/)
vnics_no=$(echo "$attached_vnics_metadata" | jq length)

if [[ "$vnics_no" -eq 1 && -n "$secondary_vnic_subnet_id" ]]; then
  echo "Attaching secondary VNIC..."

  if [[ -n "$secondary_nic_index" ]]; then
    vnic_metadata=$(oci compute instance attach-vnic --auth instance_principal --instance-id $instance_ocid --skip-source-dest-check true --nic-index $secondary_nic_index --subnet-id $secondary_vnic_subnet_id --wait)
  else
    vnic_metadata=$(oci compute instance attach-vnic --auth instance_principal --instance-id $instance_ocid --skip-source-dest-check true --subnet-id $secondary_vnic_subnet_id --wait)
  fi


  secondary_vnic_ocid=$(jq -r .data.id <<< "$vnic_metadata")

  until [[ $(curl -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/vnics/ | jq length) -eq 2 ]]; do
    echo "Waiting for secondary VNIC to be attached..."
    sleep 3
  done
  
  if [[ -n "$secondary_vnic_nsg_id" ]]; then
    oci network vnic update --auth instance_principal --vnic-id $secondary_vnic_ocid --nsg-ids "[\"$secondary_vnic_nsg_id\"]" --force
  fi
fi

if [[ -n "$secondary_vnic_subnet_id" ]]; then
  bash /root/secondary_vnic_all_configure.sh -c
  echo "Secondary VNIC configured."
fi

setup_single_uhp_bv () {

  # Check if the device exists

  bvs_http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v1/volumeAttachments/)

  if [ "$bvs_http_status" -eq 404 ]; then
    bvs=0
  else
    bvs=$(curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v1/volumeAttachments/ | jq length)
  fi

  if [ $bvs == 1 ]; then
    # Wait for UHP drive to be available
    until [ -b "$uhp_device" ]; do
      echo "Waiting for $uhp_device to become available..."
      sleep 3
    done

    until [ -b "$multipath_device" ]; do
      echo "Waiting for $multipath_device to become available..."
      sleep 3
    done

    echo "UHP block volume available."
  else
    
    instance_ad=$(jq -r .availabilityDomain <<< "$instance_metadata")
    compartment_id=$(jq -r .compartmentId <<< "$instance_metadata")
    instance_name=$(jq -r .displayName <<< "$instance_metadata")
    bv_size=$(jq --arg default_size "$default_size" -r '.metadata.bv_size // $default_size ' <<< "$instance_metadata")
    bv_vpus=$(jq --arg default_vpus "$default_vpus" -r '.metadata.bv_vpus // $default_vpus ' <<< "$instance_metadata")

    bv_metadata=$(oci bv volume create --availability-domain "$instance_ad" --compartment-id "$compartment_id" --display-name "ephemeral-bv-for-$instance_name" --freeform-tags "{\"auto-mounted-volume\": \"true\", \"parent\": \"$instance_ocid\"}" --size-in-gbs "${bv_size}" --vpus-per-gb "${bv_vpus}" --wait-for-state AVAILABLE  --auth instance_principal)

    bv_ocid=$(jq -r .data.id <<< "$bv_metadata")

    oci compute volume-attachment attach-iscsi-volume --instance-id "$instance_ocid" --volume-id "$bv_ocid" --device "$uhp_device" --is-agent-auto-iscsi-login-enabled true --wait-for-state ATTACHED --auth instance_principal

    # Wait for UHP drive to be available
    until [ -b "$uhp_device" ]; do
      echo "Waiting for $uhp_device to become available..."
      sleep 3
    done

    until [ -b "$multipath_device" ]; do
      echo "Waiting for $multipath_device to become available..."
      sleep 3
    done

    echo "UHP Disk $bv_ocid successfuly attached and available as $multipath_device device."
  fi

  # Check if the uhp device already has a filesystem
  if ! blkid "$multipath_device" > /dev/null 2>&1; then
    echo "No filesystem found on $multipath_device. Creating ext4 filesystem."
    mkfs.ext4 "$multipath_device"
  else
    echo "Filesystem already exists on $multipath_device."
  fi

  mkdir -m 0755 -p "$mount_primary"

  # Remove /etc/fstab.new file if exist
  # if [ -f "/etc/fstab.new" ]; then
  #   rm "/etc/fstab.new"
  # fi

  # Check if the device is already mounted
  if ! mount | grep -q "$multipath_device"; then
      echo "Mounting $multipath_device to $mount_primary."
      mount "$multipath_device" "$mount_primary" -t ext4 -o defaults,_netdev,nofail,x-systemd.requires=multipathd.service
      # echo "$multipath_device $mount_primary ext4 defaults,_netdev,nofail,x-systemd.requires=multipathd.service 0 2" | tee -a /etc/fstab.new
  else
      echo "$multipath_device is already mounted."
  fi
}

setup_raid () {
  # Check if the device exists

  uhp_devices=$(jq --arg default_uhp_devices "$default_uhp_devices" -r '.metadata.uhp_devices // $default_uhp_devices ' <<< "$instance_metadata")
  md_device=$(jq --arg default_md_device "$default_md_device" -r '.metadata.md_device // $default_md_device ' <<< "$instance_metadata") 
  pattern=$(jq --arg default_pattern "$default_pattern" -r '.metadata.pattern // $default_pattern ' <<< "$instance_metadata") 
  level=$(jq --arg default_level "$default_level" -r '.metadata.level // $default_level ' <<< "$instance_metadata")

  bvs_http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v1/volumeAttachments/)

  if [ "$bvs_http_status" -eq 404 ]; then
    bvs=0
  else
    bvs=$(curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v1/volumeAttachments/ | jq length)
  fi

  if [ $bvs == $uhp_devices ]; then
    modprobe dm_multipath || :

    echo "Multipath Kernel module loaded"

    until [ $uhp_devices == $(multipath -ll | grep mpath | wc -l) ]; do
      echo "Waiting for UHP Device(s) to become available..."
      sleep 3
    done

    echo "UHP device(s) available."
  else
    
    instance_ad=$(jq -r .availabilityDomain <<< "$instance_metadata")
    compartment_id=$(jq -r .compartmentId <<< "$instance_metadata")
    instance_name=$(jq -r .displayName <<< "$instance_metadata")
    bv_size=$(jq --arg default_size "$default_size" -r '.metadata.bv_size // $default_size ' <<< "$instance_metadata")
    bv_vpus=$(jq --arg default_vpus "$default_vpus" -r '.metadata.bv_vpus // $default_vpus ' <<< "$instance_metadata")


    for i in $(seq 0 $(($uhp_devices - 1))); do
      uhp_device_path=$(printf "/dev/oracleoci/oraclevd%b" "\\$(printf '%03o' $((98 + i)))")
      bv_metadata=$(oci bv volume create --availability-domain "$instance_ad" --compartment-id "$compartment_id" --display-name "ephemeral-bv$i-for-$instance_name" --freeform-tags "{\"auto-mounted-volume\": \"true\", \"parent\": \"$instance_ocid\"}" --size-in-gbs "${bv_size}" --vpus-per-gb "${bv_vpus}" --wait-for-state AVAILABLE  --auth instance_principal)  
      
      bv_ocid=$(jq -r .data.id <<< "$bv_metadata")
      oci compute volume-attachment attach-iscsi-volume --instance-id "$instance_ocid" --volume-id "$bv_ocid" --device "$uhp_device_path" --is-agent-auto-iscsi-login-enabled true --wait-for-state ATTACHED --auth instance_principal
    done
    
    modprobe dm_multipath || :
    until [ $uhp_devices == $(multipath -ll | grep mpath | wc -l) ]; do
      echo "Waiting for UHP Device(s) to become available..."
      sleep 3
    done

    echo "UHP device(s) available."
  fi

  # Enumerate multi-path attached devices, exit if absent
  devices=($pattern)
  if [ ${#devices[@]} -eq 0 ]; then
    echo "No multi-path attached devices" >&2
  fi

  # Determine config for detected device count and RAID level
  count=${#devices[@]}; bs=4; chunk=256
  stride=$((chunk/bs)) # chunk size / block size
  eff_count=$count # $level == 0
  if [[ $level == 10 ]]; then eff_count=$((count/2)); fi
  if [[ $level == 5 ]]; then eff_count=$((count-1)); fi
  if [[ $level == 6 ]]; then eff_count=$((count-2)); fi
  stripe=$((eff_count*stride)) # number of data disks * stride

  mkdir -m 0755 -p "$mount_primary"
  echo -e "Creating RAID${level} filesystem mounted under ${mount_primary} with $count devices:\n  ${devices[*]}" >&2
  echo -e "Filesystem options:\n  eff_count=$eff_count; chunk=${chunk}K; bs=${bs}K; stride=$stride; stripe-width=${stripe}" >&2
  shopt -u nullglob; seen_arrays=(/dev/md/*); device=${seen_arrays[0]}
  if [ ! -e "$md_device" ]; then
    echo "y" | mdadm --create "$md_device" --level="$level" --chunk=$chunk --force --raid-devices="$count" "${devices[@]}"
    dd if=/dev/zero of="$md_device" bs=${bs}K count=128
  else
    echo "$md_device already initialized" >&2
  fi

  if ! tune2fs -l "$md_device" &>/dev/null; then
    echo "Formatting '$md_device'" >&2
    mkfs.ext4 -I 512 -b $((bs*1024)) -E stride=${stride},stripe-width=${stripe} -O dir_index -m 1 -F "$md_device"
  else
    echo "$md_device already formatted" >&2
  fi

  # Check if the device is already mounted
  if ! mount | grep -q "$mount_primary"; then
      echo "Mounting $md_device to $mount_primary."
      mount "$md_device" "$mount_primary" -t ext4 -o defaults,noatime
  else
      echo "$md_device is already mounted."
  fi
}

mount_extras () {
  # Mount extra paths to UHP drive preserving old directory content
  for mount in "${mount_extra[@]}"; do
    temp_name="${mount//\//-}"
    name="${temp_name:1}"
    
    if [ -d "$mount" ]; then
      old_dir="${mount}-initial"
      
      if [ ! -d "$old_dir" ]; then

        echo "Directory $mount exists. Copying to $old_dir..."
        cp -a "$mount" "$old_dir"

        mkdir -m 0755 -p "$mount_primary/$name"
        mountpoint -q "$mount" || mount -vB "$mount_primary/$name" "$mount" || :
        mountpoint -q "$mount" && cp -a "$old_dir"/* "$mount" || :
      else
        echo "$old_dir already exists. Attempting only the mount."
        mkdir -m 0755 -p "$mount_primary/$name"
        mountpoint -q "$mount" || mount -vB "$mount_primary/$name" "$mount" || :
      fi
    else
      mkdir -m 0755 -p "${mount}"
      mkdir -m 0755 -p "$mount_primary/$name"
      mountpoint -q "$mount" || mount -vB "$mount_primary/$name" "$mount"
    fi

    # echo "${mount_primary}/${name} $mount none defaults,bind 0 2" | tee -a /etc/fstab.new
  done

}

# Setup UHP BVs
create_bv=$(jq --arg create_bv "$default_create_bv" -r '.metadata.create_bv // $create_bv ' <<< "$instance_metadata")

# Check if it's necessary to create device
if [ $create_bv == "false" ]; then
    echo "No request for additional Block Volume."
else
    setup_single_uhp_bv
    mount_extras
fi

# Setup RAID
create_raid=$(jq --arg create_raid "$default_create_raid" -r '.metadata.create_raid // $create_raid ' <<< "$instance_metadata")

# Check if it's necessary to create device
if [ $create_raid == "false" ]; then
    echo "No request to setup RAID."
else
    setup_raid
    mount_extras
fi

# # Backup fstab
# if [ ! -e "/etc/fstab.bkp" ]; then
#   cp /etc/fstab /etc/fstab.bkp
# fi

# # Update persistent filesystem mounts
# while IFS= read -r line; do
#   if ! grep -Fxq "$line" /etc/fstab; then
#     echo "$line" >> /etc/fstab
#   fi
# done < /etc/fstab.new

echo "Mount script successfuly executed"
