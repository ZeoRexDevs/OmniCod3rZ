#!/bin/bash
set -euo pipefail

# Workflow-local copy: rebuild /data before the external scripts repository is cloned.
# Keep this standalone so runner setup does not depend on the external scripts checkout.
# The .maximized.lock marker proves that the runner's data volume has been created.
if [[ -f /data/.maximized.lock ]]; then
  echo "[!] Refusing to remount /data after the .maximized.lock marker exists; this would hide /data/scripts." >&2
  exit 2
fi

###
#> CHANGEABLE: "${ROOT_RESERVE_MB:-8196}" "${TEMP_RESERVE_MB:-512}" "${SWAP_SIZE_MB:-4096}"
#> OPTIONAL: ${{ slimRoot == 0|1|2 }}
###

echo "::group::[</>] Maximize Space, v2 (Optimized)"

export root_reserve_mb="${ROOT_RESERVE_MB:-8196}"
export temp_reserve_mb="${TEMP_RESERVE_MB:-512}"
export swap_size_mb="${SWAP_SIZE_MB:-4096}"
export build_mount_path="/data"
export pv_loop_path="/pv.img"
export tmp_pv_loop_path="/mnt/tmp-pv.img"
export VG_NAME="buildvg"
export slimRoot="${slimRoot:-0}"

# 1. Optional Deep Clean via slimhub_actions (slimRoot=2)
if [[ "${slimRoot}" -eq 2 ]]; then
  echo "[i] Executing slimhub_actions cleanup..."
  export retain="docker_buildkit"
  curl -sL --retry 5 "https://github.com/rokibhasansagar/slimhub_actions/raw/refs/heads/main/cleanup.sh" \
    | sed '10,14d' | sed 's|apt-fast|apt-get|g' | bash
fi

echo -e "[i] Initial Space:"
df --sync -BM -lT
echo

# 2. Clean Docker Images & Toolcaches
echo "[i] Cleaning Up Docker Images..."
docker_imgs=$(docker images -q)
if [[ -n "${docker_imgs}" ]]; then
  docker rmi -f ${docker_imgs} &>/dev/null || true
fi

if [[ "${slimRoot}" -eq 1 ]]; then
  echo "[i] Removing pre-installed runner SDKs (slimRoot=1)..."
  sudo rm -rf -- \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /opt/hostedtoolcache \
    /usr/local/share/vcpkg \
    /usr/share/rust \
    /home/runner/.cargo \
    /usr/share/kotlinc \
    /usr/local/julia* 2>/dev/null || true
fi

# 3. Prepare Mount & Disable Default Swap
sudo mkdir -p "${build_mount_path}"

echo "[i] Unmounting and removing default /mnt/swapfile..."
sudo swapoff -a && sudo rm -f /mnt/swapfile

# 4. Allocate Loop PVs using Native Bash Arithmetic.
# Some runners have a dedicated /mnt filesystem; others have /mnt as an ordinary
# directory on /. Only use /mnt as a second PV when it is mounted on a distinct
# filesystem. Creating two PV files on the same filesystem would double-count the
# same free space and can make the allocation fail or exhaust the root filesystem.
echo "[i] Detecting available filesystems for LVM..."
HAS_SEPARATE_TMP_FS=0
if mountpoint -q /mnt; then
  ROOT_FS_DEVICE_ID=$(stat -c '%d' /)
  TMP_FS_DEVICE_ID=$(stat -c '%d' /mnt)
  if [[ "${ROOT_FS_DEVICE_ID}" != "${TMP_FS_DEVICE_ID}" ]]; then
    HAS_SEPARATE_TMP_FS=1
    echo "  -> /mnt is a separate filesystem; both root and temp space will be used."
  else
    echo "  -> /mnt is a mountpoint on the same filesystem as /; using root space only."
  fi
else
  echo "  -> /mnt is not a separate mountpoint; using root space only."
fi

echo "[i] Creating LVM Physical Volumes..."
echo "  -> Allocating Root FS Loop PV..."
ROOT_RESERVE_KB=$((root_reserve_mb * 1024))
ROOT_FREE_KB=$(df --block-size=1024 --output=avail / | tail -1 | tr -d ' ')
ROOT_LVM_SIZE_KB=$((ROOT_FREE_KB - ROOT_RESERVE_KB))
if (( ROOT_LVM_SIZE_KB <= 0 )); then
  echo "[!] Not enough free space on / after reserving ${root_reserve_mb} MB." >&2
  exit 1
fi
ROOT_LVM_SIZE_BYTES=$((ROOT_LVM_SIZE_KB * 1024))

sudo touch "${pv_loop_path}"
sudo fallocate -z -l "${ROOT_LVM_SIZE_BYTES}" "${pv_loop_path}"
ROOT_LOOP_DEV=$(sudo losetup --find --show "${pv_loop_path}")
sudo pvcreate -f "${ROOT_LOOP_DEV}"

# Start with the root PV. Add the temp PV only when /mnt has independent capacity.
PV_DEVICES=("${ROOT_LOOP_DEV}")
TOTAL_LVM_SIZE_KB=${ROOT_LVM_SIZE_KB}
if (( HAS_SEPARATE_TMP_FS == 1 )); then
  echo "  -> Allocating Temp FS (/mnt) Loop PV..."
  TMP_RESERVE_KB=$((temp_reserve_mb * 1024))
  TMP_FREE_KB=$(df --block-size=1024 --output=avail /mnt | tail -1 | tr -d ' ')
  TMP_LVM_SIZE_KB=$((TMP_FREE_KB - TMP_RESERVE_KB))
  if (( TMP_LVM_SIZE_KB <= 0 )); then
    echo "[!] Not enough free space on /mnt after reserving ${temp_reserve_mb} MB." >&2
    exit 1
  fi
  TMP_LVM_SIZE_BYTES=$((TMP_LVM_SIZE_KB * 1024))

  sudo touch "${tmp_pv_loop_path}"
  sudo fallocate -z -l "${TMP_LVM_SIZE_BYTES}" "${tmp_pv_loop_path}"
  TMP_LOOP_DEV=$(sudo losetup --find --show "${tmp_pv_loop_path}")
  sudo pvcreate -f "${TMP_LOOP_DEV}"
  PV_DEVICES+=("${TMP_LOOP_DEV}")
  TOTAL_LVM_SIZE_KB=$((TOTAL_LVM_SIZE_KB + TMP_LVM_SIZE_KB))
fi

if (( TOTAL_LVM_SIZE_KB <= swap_size_mb * 1024 )); then
  echo "[!] Combined LVM space is not large enough for the requested ${swap_size_mb} MB swap volume." >&2
  exit 1
fi

# 5. Build Volume Group, Swap LV & Build LV
echo "[i] Creating Volume Group (${VG_NAME})..."
sudo vgcreate "${VG_NAME}" "${PV_DEVICES[@]}"

echo "[i] Recreating Swap Volume (${swap_size_mb}M)..."
sudo lvcreate -L "${swap_size_mb}M" -n swap "${VG_NAME}"
sudo mkswap "/dev/mapper/${VG_NAME}-swap"
sudo swapon "/dev/mapper/${VG_NAME}-swap"

echo "[i] Creating and Mounting /data Logical Volume..."
sudo lvcreate -l 100%FREE -n buildlv "${VG_NAME}"
sudo mkfs.ext4 -Enodiscard -m0 "/dev/mapper/${VG_NAME}-buildlv"
sudo mount "/dev/mapper/${VG_NAME}-buildlv" "${build_mount_path}"

# 6. Permissions & Workspace Restoration
workspace_owner="runner:runner"
if [[ -n "${GITHUB_WORKSPACE:-}" ]] && [[ -d "${GITHUB_WORKSPACE}" ]]; then
  workspace_owner="$(stat -c '%U:%G' "${GITHUB_WORKSPACE}" 2>/dev/null || echo "runner:runner")"
fi
sudo chown -R "${workspace_owner}" "${build_mount_path}"

echo "Cleaned by CSSR" > "${build_mount_path}/.maximized.lock"

if [[ -n "${GITHUB_WORKSPACE:-}" ]] && [[ ! -d "${GITHUB_WORKSPACE}" ]]; then
  echo "[i] Recreating GitHub workspace: ${GITHUB_WORKSPACE}"
  sudo mkdir -p "${GITHUB_WORKSPACE}"
  sudo chown -R "${workspace_owner}" "${GITHUB_WORKSPACE}"
fi

echo -e "\n[i] Final Space:"
df --sync -BM -lT
echo

echo "::endgroup::"

