#!/bin/bash
#
# This script will determine which interface has PTP enabled on its switch
# port (if any) based on info in the Cloudlab manifest and will startup `ptp4l`
# (to sync with switch) and `phc2sys` (to sync system clock with PTP).
# 

# Maybe someday selectable, but probably not
PROFILE="G8275-1"

# Path to our installed repository directory
REPO=/local/repository

# Sanity checks
if [ $UID -ne 0 ]; then
  echo "Startup must be run as root (not $UID)"
  exit 1
fi

# Install any needed packages
pkgs=""
if [ ! -f /usr/share/perl5/XML/Simple.pm ]; then
  # XXX for parsing the manifest in getmanifest
  pkgs="$pkgs libxml-simple-perl"
fi
if [ ! -x /usr/sbin/ptp4l ]; then
  pkgs="$pkgs linuxptp"
fi
if [ -n "$pkgs" ]; then
  echo "Installing packages, see /tmp/apt.log for details."
  apt-get update >/tmp/apt.log 2>&1
  apt-get install -y --no-install-recommends $pkgs >>/tmp/apt.log 2>&1
fi

# Figure out which interface has PTP enabled
IFACE=`$REPO/bin/getptpiface`
if [ $? -ne 0 ]; then
  echo "Cannot determine PTP interface."
  exit 1
fi

echo "Configuring ptp4l on $IFACE..."

# Setup PTP config
PTPCONF=/etc/linuxptp/ptp4l.conf
if [ ! -f "$PTPCONF" ] || ! cmp -s $PTPCONF $REPO/etc/ptp4l/ptp4l-$PROFILE.conf; then
  cp $REPO/etc/ptp4l/ptp4l-$PROFILE.conf $PTPCONF
fi

echo "Configuring phc2sys to use PHC on $IFACE..."

# XXX ensure startup script for phc2sys is right (Ubuntu 22 version has a bug)
if ! cmp -s /lib/systemd/system/phc2sys@.service $REPO/etc/services/phc2sys@.service; then
  cp $REPO/etc/services/phc2sys@.service /lib/systemd/system/phc2sys@.service
fi

# Make sure the interface is up. It is possible it has no IP address.
ifconfig $IFACE up

# Disable NTP, we will be syncing the system clock to PTP
if systemctl -q is-active ntp; then
  echo "Deactivating NTP..."
  systemctl stop ntp.service
  systemctl disable ntp.service
fi

if ! systemctl -q is-active ptp4l@$IFACE.service; then
  # Enable PTP services
  systemctl start ptp4l@$IFACE.service
  systemctl start phc2sys@$IFACE.service
  # and make them permanent
  systemctl enable ptp4l@$IFACE.service
  systemctl enable phc2sys@$IFACE.service
fi

echo "PTP activated. Tail the logs with:"
echo "  sudo journalctl -f -u ptp4l@$IFACE.service"
echo "  sudo journalctl -f -u phc2sys@$IFACE.service"
