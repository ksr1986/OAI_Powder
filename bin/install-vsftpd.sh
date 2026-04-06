#!/bin/sh
set -x

if [ -e "/etc/.ftp-installed"]; then
    exit 0
fi
sudo apt-get update

sudo apt-get -y install --no-install-recommends vsftpd
if [ $? -ne 0 ]; then
    echo 'ERROR: install vsftpd'
    exit 1
fi
sudo systemctl stop vsftpd

cat << EOF >> /tmp/vsftp.conf
listen=YES
listen_ipv6=NO
write_enable=YES
chroot_local_user=YES
user_sub_token=\$USER
local_root=/home/\$USER/ftp
pasv_min_port=40000
pasv_max_port=50000
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
allow_writeable_chroot=YES
listen_address=10.45.0.1
EOF
cat /tmp/vsftp.conf | sudo tee -a /etc/vsftpd.conf
if [ $? -ne 0 ]; then
    echo 'ERROR: updating /etc/vsftpd.conf'
    exit 1
fi

echo "totaman" | sudo tee -a /etc/vsftpd.userlist
if [ $? -ne 0 ]; then
    echo 'ERROR: creating /etc/vsftpd.userlist'
    exit 1
fi

if [ ! -e "/home/totaman" ]; then
    sudo adduser --disabled-login --gecos 'Tota Man' totaman
    if [ $? -ne 0 ]; then
	echo 'ERROR: creating totaman account'
	exit 1
    fi
fi
echo 'totaman:randopass' | sudo chpasswd
if [ $? -ne 0 ]; then
    echo 'ERROR: setting totaman password'
    exit 1
fi
sudo mkdir /home/totaman/ftp && sudo chown totaman:totaman /home/totaman/ftp
if [ $? -ne 0 ]; then
    echo 'ERROR: create totaman ftp directory'
    exit 1
fi
sudo systemctl start vsftpd

sudo touch /etc/.ftp-installed
exit 0
