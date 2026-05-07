#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# configure_shares.sh — Configure SMB (Samba/ksmbd) and NFS sharing for /mnt
#
# Security profiles:
#   open    -> Samba guest + wide links + NFS no_root_squash
#   limited -> Samba guest restricted to local interface/subnet + NFS root_squash
#   secure  -> Samba valid users only, interface/subnet restricted, NFS disabled
# ---------------------------------------------------------------------------

MOUNT_PARENT="/mnt"
SHARE_NAME="mnt"
SAMBA_CONF="/etc/samba/smb.conf"
NFS_EXPORTS="/etc/exports.d/automount-pve.exports"

declare -A POSTURE_SMB_GUEST=(
    [open]=yes
    [limited]=yes
    [secure]=no
)

declare -A POSTURE_WIDE_LINKS=(
    [open]=yes
    [limited]=no
    [secure]=no
)

declare -A POSTURE_RESTRICT_NET=(
    [open]=no
    [limited]=yes
    [secure]=yes
)

declare -A POSTURE_ENABLE_NFS=(
    [open]=yes
    [limited]=yes
    [secure]=no
)

declare -A POSTURE_ROOT_SQUASH=(
    [open]=no_root_squash
    [limited]=root_squash
    [secure]=root_squash
)

# Colours for terminal output (no-op when piped)
if [[ -t 1 ]]; then
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log()  { echo "${C_GREEN}[configure_shares]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[configure_shares] WARNING:${C_RESET} $*" >&2; }
err()  { echo "${C_RED}[configure_shares] ERROR:${C_RESET} $*" >&2; }

prompt_yn() {
    local prompt ans def
    prompt="$1" def="$2"
    [[ -t 0 ]] || return 0
    while true; do
        read -rp "$prompt [$def]: " ans
        ans="${ans:-$def}"
        case "${ans,,}" in y|yes) return 0 ;; n|no) return 1 ;; esac
    done
}

backup_file() {
    local f ts
    f="$1"
    [[ -f "$f" ]] || return
    ts="$(date +%Y%m%d%H%M%S)"
    cp -a "$f" "$f.bak.$ts"
    log "Backed up $f -> $f.bak.$ts"
}

detect_subnet() {
    local ip
    ip=$(ip -4 -o addr show scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
    [[ -n "$ip" ]] && echo "${ip%.*}.0/24" || echo "192.168.1.0/24"
}

detect_ifaces() {
    ip -o -4 addr show scope global | awk '{print $2}' | sort -u | paste -sd' ' -
}

choose_posture() {
    local p
    if [[ -t 0 ]]; then
        echo "${C_YELLOW}Security warning summary:${C_RESET}"
        echo "  - Guest SMB access lets unauthenticated clients access files."
        echo "  - Wide links + symlinks can expose files outside ${MOUNT_PARENT}."
        echo "  - NFS root_squash reduces risk; no_root_squash is less secure."
        echo ""
        echo "Security profiles:"
        echo "  open    -> guest ok, wide links, NFS no_root_squash"
        echo "  limited -> guest ok, no wide links, subnet restricted, NFS root_squash"
        echo "  secure  -> valid users only, subnet restricted, NFS disabled"
        echo ""
        read -rp "Choose posture (open/limited/secure) [open]: " p
        echo ""
        POSTURE="${p:-open}"
    else
        POSTURE="open"
    fi
}

install_samba_if_needed() {
    if ! command -v smbd >/dev/null 2>&1; then
        warn "Samba not installed. Installing..."
        apt-get update -qq && apt-get install -y samba
    fi
}

install_nfs_if_needed() {
    [[ "${POSTURE_ENABLE_NFS[$POSTURE]}" == "yes" ]] || return
    if ! command -v exportfs >/dev/null 2>&1; then
        warn "NFS server not installed. Installing..."
        apt-get update -qq && apt-get install -y nfs-kernel-server
    fi
}

render_samba_config() {
    local guest wide restrict subnet iface hosts
    guest="${POSTURE_SMB_GUEST[$POSTURE]}"
    wide="${POSTURE_WIDE_LINKS[$POSTURE]}"
    restrict="${POSTURE_RESTRICT_NET[$POSTURE]}"

    if [[ "$restrict" == "yes" ]]; then
        subnet="$(detect_subnet)"
        iface="$(detect_ifaces)"
        hosts="$subnet fe80::/10 127.0.0.0/8"
    fi

    cat <<EOF
[global]
   workgroup = WORKGROUP
   server string = Proxmox USB Automount Share

   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   obey pam restrictions = yes
   usershare allow guests = yes

$( [[ "$guest" == "yes" ]] && echo "   map to guest = Bad User
   guest account = nobody" )

$( [[ "$wide" == "yes" ]] && echo "   unix extensions = no
   allow insecure wide links = yes" )

$( [[ "$restrict" == "yes" ]] && echo "   hosts allow = $hosts
   interfaces = lo $iface
   bind interfaces only = yes" )

# MacOS compatibility settings
# do not ever add time machine support or spotlight indexing
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:resource = stream
   fruit:locking = none
   fruit:encoding = native
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   fruit:aapl = yes
   veto files = /._*/.DS_Store/.TemporaryItems/.Trashes/
   delete veto files = yes
   case sensitive = auto
   directory name cache size = 0
   kernel share modes = no

[${SHARE_NAME}]
   path = ${MOUNT_PARENT}
   browseable = yes
   writable = yes
   create mask = 0664
   directory mask = 0775

$( [[ "$guest" == "yes" ]] && echo "   guest ok = yes
   force user = root
   force group = root" || echo "   guest ok = no
   valid users = root" )

$( [[ "$wide" == "yes" ]] && echo "   wide links = yes
   follow symlinks = yes" )
EOF
}

apply_samba() {
    install_samba_if_needed
    local cfg
    cfg="$(render_samba_config)"

    if [[ -f "$SAMBA_CONF" && -t 0 ]]; then
        if ! prompt_yn "Overwrite existing $SAMBA_CONF? [default: yes]" "y"; then
          warn "Keeping existing $SAMBA_CONF."
          echo "Here is the generated configuration if you want to implement it manually:"
          echo ""
          printf '%s\n' "$cfg"
          echo ""
          return
        fi
    fi

    backup_file "$SAMBA_CONF"
    printf '%s\n' "$cfg" > "$SAMBA_CONF"
    systemctl enable --now smbd || warn "Could not start smbd"
    systemctl reload smbd || true
    log "Samba configured."
}

apply_nfs() {
    [[ "${POSTURE_ENABLE_NFS[$POSTURE]}" == "yes" ]] || {
        log "NFS disabled by posture."
        return
    }

    install_nfs_if_needed

    local subnet opts
    subnet="$(detect_subnet)"
    opts="rw,sync,no_subtree_check,crossmnt,fsid=0,${POSTURE_ROOT_SQUASH[$POSTURE]},insecure"

    backup_file "$NFS_EXPORTS"
    cat > "$NFS_EXPORTS" <<EOF
${MOUNT_PARENT}  ${subnet}(${opts})
${MOUNT_PARENT}  fe80::/10(${opts})
EOF

    exportfs -ra || true
    systemctl enable --now nfs-kernel-server || warn "Could not start NFS"
    log "NFS configured."
}

main() {
    choose_posture
    log "Selected posture: $POSTURE"

    apply_samba
    apply_nfs

    log "Share configuration complete."
}

main "$@"
