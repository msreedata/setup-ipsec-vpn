#!/bin/bash
#
# Script to update Libreswan on Alpine Linux
#
# The latest version of this script is available at:
# https://github.com/msreedata/setup-ipsec-vpn
#
# Copyright (C) 2021 Lin Song <linsongui@gmail.com>
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# Specify which Libreswan version to install. See: https://libreswan.org
SWAN_VER=4.6

### DO NOT edit below this line ###

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -n "$VPN_UPDATE_SWAN_VER" ] && SWAN_VER="$VPN_UPDATE_SWAN_VER"

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'apk add' failed."; }
bigecho() { echo "## $1"; }

check_root() {
  if [ "$(id -u)" != 0 ]; then
    exiterr "Script must be run as root. Try 'sudo bash $0'"
  fi
}

check_vz() {
  if [ -f /proc/user_beancounters ]; then
    exiterr "OpenVZ VPS is not supported."
  fi
}

check_os() {
  os_type=$(lsb_release -si 2>/dev/null)
  os_arch=$(uname -m | tr -dc 'A-Za-z0-9_-')
  [ -z "$os_type" ] && [ -f /etc/os-release ] && os_type=$(. /etc/os-release && printf '%s' "$ID")
  case $os_type in
    [Aa]lpine)
      os_type=alpine
      ;;
    *)
      exiterr "This script only supports Alpine Linux."
      ;;
  esac
  os_ver=$(. /etc/os-release && printf '%s' "$VERSION_ID" | cut -d '.' -f 1,2)
  if [ "$os_ver" != "3.14" ]; then
    exiterr "This script only supports Alpine Linux 3.14."
  fi
}

check_libreswan() {
  case $SWAN_VER in
    4.6)
      true
      ;;
    *)
cat 1>&2 <<EOF
Error: Libreswan version '$SWAN_VER' is not supported.
       This script can install Libreswan 4.6.
EOF
      exit 1
      ;;
  esac

  ipsec_ver=$(/usr/local/sbin/ipsec --version 2>/dev/null)
  swan_ver_old=$(printf '%s' "$ipsec_ver" | sed -e 's/.*Libreswan U\?//' -e 's/\( (\|\/K\).*//')
  if ! printf '%s' "$ipsec_ver" | grep -q "Libreswan"; then
cat 1>&2 <<'EOF'
Error: This script requires Libreswan already installed.
       See: https://github.com/msreedata/setup-ipsec-vpn
EOF
    exit 1
  fi

  if [ "$swan_ver_old" = "$SWAN_VER" ]; then
cat <<EOF
You already have Libreswan version $SWAN_VER installed!
If you continue, the same version will be re-installed.

EOF
    printf "Do you want to continue anyway? [y/N] "
    read -r response
    case $response in
      [yY][eE][sS]|[yY])
        echo
        ;;
      *)
        echo "Abort. No changes were made."
        exit 1
        ;;
    esac
  fi
}

show_setup_info() {
cat <<EOF

Welcome! Use this script to update Libreswan on your IPsec VPN server.

Current version:    Libreswan $swan_ver_old
Version to install: Libreswan $SWAN_VER

Note: This script will make the following changes to your VPN configuration:
      - Fix obsolete ipsec.conf and/or ikev2.conf options
      - Optimize VPN ciphers
      Your other VPN config files will not be modified.

EOF

  if [ "$SWAN_VER" != "4.6" ]; then
cat <<'EOF'
WARNING: Older versions of Libreswan could contain known security vulnerabilities.
         See https://libreswan.org/security/ for more information.
         Are you sure you want to install an older version?

EOF
  fi

  printf "Do you want to continue? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Abort. No changes were made."
      exit 1
      ;;
  esac
}

start_setup() {
  # shellcheck disable=SC2154
  trap 'dlo=$dl;dl=$LINENO' DEBUG 2>/dev/null
  trap 'finish $? $((dlo+1))' EXIT
  mkdir -p /opt/src
  cd /opt/src || exit 1
}

install_pkgs() {
  bigecho "Installing required packages..."
  (
    set -x
    apk add -U -q bash bind-tools coreutils openssl wget iproute2 sed grep \
    libcap-ng libcurl libevent linux-pam musl nspr nss nss-tools \
    bison flex gcc make libc-dev bsd-compat-headers linux-pam-dev nss-dev \
    libcap-ng-dev libevent-dev curl-dev nspr-dev uuidgen openrc
  ) || exiterr2
}

get_libreswan() {
  bigecho "Downloading Libreswan..."
  swan_file="libreswan-$SWAN_VER.tar.gz"
  swan_url1="https://github.com/libreswan/libreswan/archive/v$SWAN_VER.tar.gz"
  swan_url2="https://download.libreswan.org/$swan_file"
  (
    set -x
    wget -t 3 -T 30 -q -O "$swan_file" "$swan_url1" || wget -t 3 -T 30 -q -O "$swan_file" "$swan_url2"
  ) || exit 1
  /bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
  tar xzf "$swan_file" && /bin/rm -f "$swan_file"
}

install_libreswan() {
  bigecho "Compiling and installing Libreswan, please wait..."
  cd "libreswan-$SWAN_VER" || exit 1
  sed -i '28s/stdlib\.h/sys\/types.h/' include/fd.h
cat > Makefile.inc.local <<'EOF'
WERROR_CFLAGS=-w -s
USE_DNSSEC=false
USE_DH2=true
FINALNSSDIR=/etc/ipsec.d
USE_GLIBC_KERN_FLIP_HEADERS=true
EOF
  NPROCS=$(grep -c ^processor /proc/cpuinfo)
  [ -z "$NPROCS" ] && NPROCS=1
  (
    set -x
    make "-j$((NPROCS+1))" -s base >/dev/null && make -s install-base >/dev/null
  )

  cd /opt/src || exit 1
  /bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
  if ! /usr/local/sbin/ipsec --version 2>/dev/null | grep -qF "$SWAN_VER"; then
    exiterr "Libreswan $SWAN_VER failed to build."
  fi
}

update_config() {
  bigecho "Updating VPN configuration..."
  IKE_NEW="  ike=aes256-sha2,aes128-sha2,aes256-sha1,aes128-sha1,aes256-sha2;modp1024,aes128-sha1;modp1024"
  PHASE2_NEW="  phase2alg=aes_gcm-null,aes128-sha1,aes256-sha1,aes256-sha2_512,aes128-sha2,aes256-sha2"

  if uname -m | grep -qi '^arm'; then
    if ! modprobe -q sha512; then
      PHASE2_NEW="  phase2alg=aes_gcm-null,aes128-sha1,aes256-sha1,aes128-sha2,aes256-sha2"
    fi
  fi

  dns_state=0
  DNS_SRV1=$(grep "modecfgdns1=" /etc/ipsec.conf | head -n 1 | cut -d '=' -f 2)
  DNS_SRV2=$(grep "modecfgdns2=" /etc/ipsec.conf | head -n 1 | cut -d '=' -f 2)
  [ -n "$DNS_SRV1" ] && dns_state=2
  [ -n "$DNS_SRV1" ] && [ -n "$DNS_SRV2" ] && dns_state=1
  [ "$(grep -c "modecfgdns1=" /etc/ipsec.conf)" -gt "1" ] && dns_state=3

  sed -i".old-$(date +%F-%T)" \
      -e "s/^[[:space:]]\+auth=/  phase2=/" \
      -e "s/^[[:space:]]\+forceencaps=/  encapsulation=/" \
      -e "s/^[[:space:]]\+ike-frag=/  fragmentation=/" \
      -e "s/^[[:space:]]\+sha2_truncbug=/  sha2-truncbug=/" \
      -e "s/^[[:space:]]\+sha2-truncbug=yes/  sha2-truncbug=no/" \
      -e "s/^[[:space:]]\+ike=.\+/$IKE_NEW/" \
      -e "s/^[[:space:]]\+phase2alg=.\+/$PHASE2_NEW/" /etc/ipsec.conf

  if [ "$dns_state" = "1" ]; then
    sed -i -e "s/^[[:space:]]\+modecfgdns1=.\+/  modecfgdns=\"$DNS_SRV1 $DNS_SRV2\"/" \
        -e "/modecfgdns2=/d" /etc/ipsec.conf
  elif [ "$dns_state" = "2" ]; then
    sed -i "s/^[[:space:]]\+modecfgdns1=.\+/  modecfgdns=$DNS_SRV1/" /etc/ipsec.conf
  fi

  sed -i "/ikev2=never/d" /etc/ipsec.conf
  sed -i "/conn shared/a \  ikev2=never" /etc/ipsec.conf

  if grep -qs ike-frag /etc/ipsec.d/ikev2.conf; then
    sed -i 's/^[[:space:]]\+ike-frag=/  fragmentation=/' /etc/ipsec.d/ikev2.conf
  fi
}

restart_ipsec() {
  bigecho "Restarting IPsec service..."
  mkdir -p /run/pluto
  service ipsec restart >/dev/null 2>&1
}

show_setup_complete() {
cat <<EOF

================================================

Libreswan $SWAN_VER has been successfully installed!

================================================

EOF

  if [ "$dns_state" = "3" ]; then
cat <<'EOF'
IMPORTANT: You must edit /etc/ipsec.conf and replace
           all occurrences of these two lines:
             modecfgdns1=DNS_SERVER_1
             modecfgdns2=DNS_SERVER_2

           with a single line like this:
             modecfgdns="DNS_SERVER_1 DNS_SERVER_2"

           Then run "sudo service ipsec restart".

EOF
  fi
}

check_swan_ver() {
  swan_ver_cur=4.6
  swan_ver_url="https://dl.ls20.com/v1/$os_type/$os_ver/swanverupg?arch=$os_arch&ver1=$swan_ver_old&ver2=$SWAN_VER"
  [ "$1" != "0" ] && swan_ver_url="$swan_ver_url&e=$2"
  swan_ver_latest=$(wget -t 3 -T 15 -qO- "$swan_ver_url")
  if printf '%s' "$swan_ver_latest" | grep -Eq '^([3-9]|[1-9][0-9]{1,2})(\.([0-9]|[1-9][0-9]{1,2})){1,2}$' \
    && [ "$1" = "0" ] && [ "$swan_ver_cur" != "$swan_ver_latest" ] \
    && printf '%s\n%s' "$swan_ver_cur" "$swan_ver_latest" | sort -C -V; then
cat <<EOF
Note: A newer version of Libreswan ($swan_ver_latest) is available.
      To update, run:
      wget https://git.io/vpnupgrade -O vpnup.sh && sudo sh vpnup.sh

EOF
  fi
}

finish() {
  check_swan_ver "$1" "$2"
  exit "$1"
}

vpnupgrade() {
  check_root
  check_vz
  check_os
  check_libreswan
  show_setup_info
  start_setup
  install_pkgs
  get_libreswan
  install_libreswan
  update_config
  restart_ipsec
  show_setup_complete
}

## Defer setup until we have the complete script
vpnupgrade "$@"

exit 0
