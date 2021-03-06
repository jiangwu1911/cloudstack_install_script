#!/bin/bash

SSH_PUBLIC_KEY='insert_your_ssh_public_key_here'

function add_ssh_public_key() {
    cd
    mkdir -p .ssh
    chmod 700 .ssh
    echo "$SSH_PUBLIC_KEY" >> .ssh/authorized_keys
    chmod 600 .ssh/authorized_keys
}

function get_input() {
    read -p " $1 (default: $2) : " VAR
    if [ -z $VAR ]; then
        VAR=$2
    fi
    eval $3=$VAR
}

function get_network_info() {
    echo '* settings for cloud agent'

    default_route=$(ip route show)
    default_interface=$(echo $default_route | sed -e 's/^.*dev \([^ ]*\).*$/\1/' | head -n 1)
    address=$(ip addr show label $default_interface scope global | awk '$1 == "inet" { print $2,$4}')
    ip=$(echo $address | awk '{print $1 }')
    ip=${ip%%/*}
    broadcast=$(echo $address | awk '{print $2 }')
    mask=$(route -n |grep 'U[ \t]' | head -n 1 | awk '{print $3}')
    gateway=$(route -n | grep 'UG[ \t]' | awk '{print $2}')
    dns=$(cat /etc/resolv.conf | grep nameserver | head -n 1 | awk '{print $2}')
    fqdn=`hostname --fqdn`
  
    get_input ' hostname'   $fqdn       FQDN
    get_input ' ip address' $ip         IPADDR
    get_input ' netmask'    $mask       NETMASK
    get_input ' gateway'    $gateway    GATEWAY
    get_input ' dns1'       $dns        DNS1
    get_input ' dns2'       '8.8.8.8'   DNS2
    HOSTNAME=`echo $FQDN | cut -d. -f1`
    DOMAIN=`echo $FQDN | cut -d. -f2-`
}

function get_nfs_info() {
    echo '* settings for nfs server'
    get_input ' NFS Server IP' $IPADDR              NFS_SERVER_IP
    get_input ' Primary mount point' '/primary'     NFS_SERVER_PRIMARY
    get_input ' Secondary mount point' '/secondary' NFS_SERVER_SECONDARY
}

function get_nfs_network() {
    echo '* settings for nfs server'
    net=$(echo $IPADDR | cut -d. -f1-3)'.0/24'
    get_input ' accept access from' $net            NETWORK
}

function install_common() {
    yum update -y
    sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
    setenforce Permissive
    echo "[cloudstack]
name=cloudstack
baseurl=http://192.168.1.124/4.3/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/CloudStack.repo
    echo "$IPADDR $HOSTNAME.$DOMAIN $HOSTNAME" >> /etc/hosts
    yum install ntp wget -y
    service ntpd start
    chkconfig ntpd on
}

function install_management() {
    yum install cloud-client mysql-server expect -y

    head -7 /etc/my.cnf > /tmp/before
    tail -n +7 /etc/my.cnf > /tmp/after
    cat /tmp/before > /etc/my.cnf
    echo "innodb_rollback_on_timeout=1
innodb_lock_wait_timeout=600
max_connections=350
log-bin=mysql-bin
binlog-format = 'ROW'" >> /etc/my.cnf
    cat /tmp/after >> /etc/my.cnf
    rm -rf /tmp/before /tmp/after

    service mysqld start
    chkconfig mysqld on

    expect -c "
set timeout 10
spawn mysql_secure_installation
expect \"Enter current password for root (enter for none): \"
send \"\n\"
expect \"Set root password?\"
send \"Y\n\"
expect \"New password: \"
send \"password\n\"
expect \"Re-enter new password: \"
send \"password\n\"
expect \"Remove anonymous users?\"
send \"Y\n\"
expect \"Disallow root login remotely?\"
send \"Y\n\"
expect \"Remove test database and access to it?\"
send \"Y\n\"
expect \"Reload privilege tables now?\"
send \"Y\n\"
interact
"
    cloudstack-setup-databases cloud:password@localhost --deploy-as=root:password
    echo "Defaults:cloud !requiretty" >> /etc/sudoers
    cloudstack-setup-management
    chown cloud:cloud /var/log/cloudstack/management/catalina.out
}

function initialize_storage() {
    service rpcbind start
    chkconfig rpcbind on
    service nfs start
    chkconfig nfs on
    mkdir -p /mnt/primary
    mkdir -p /mnt/secondary
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_PRIMARY} /mnt/primary
    sleep 10
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_SECONDARY} /mnt/secondary
    sleep 10
    rm -rf /mnt/primary/*
    rm -rf /mnt/secondary/*
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m /mnt/secondary -u http://192.168.1.124/systemvm64template-2014-01-14-master-kvm.qcow2.bz2 -h kvm -F
    sync
    umount /mnt/primary
    umount /mnt/secondary
    rmdir /mnt/primary
    rmdir /mnt/secondary
}

function install_agent() {
    yum install qemu-kvm cloud-agent bridge-utils vconfig -y
    modprobe kvm-intel
    echo "group virt {
        cpu {
            cpu.shares=9216;
        }
}" >> /etc/cgconfig.conf
    service cgconfig restart

    echo "vnc_listen = \"0.0.0.0\"" >> /etc/libvirt/qemu.conf

    echo "listen_tls = 0
listen_tcp = 1
tcp_port = \"16509\"
auth_tcp = \"none\"
mdns_adv = 0" >> /etc/libvirt/libvirtd.conf
    sed -i -e 's/#LIBVIRTD_ARGS="--listen"/LIBVIRTD_ARGS="--listen"/g' /etc/sysconfig/libvirtd
    service libvirtd restart

    HWADDR=`grep HWADDR /etc/sysconfig/network-scripts/ifcfg-eth0 | awk -F '"' '{print $2}'`

    echo "DEVICE=eth0
HWADDR=$HWADDR
NM_CONTROLLED=no
ONBOOT=yes
IPADDR=$IPADDR
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
BRIDGE=cloudbr0" > /etc/sysconfig/network-scripts/ifcfg-eth0
    echo "DEVICE=cloudbr0
HWADDR=$HWADDR
NM_CONTROLLED=no
ONBOOT=yes
IPADDR=$IPADDR
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
TYPE=Bridge" > /etc/sysconfig/network-scripts/ifcfg-cloudbr0
}

function install_nfs() {
    yum install nfs-utils -y
    service rpcbind start
    chkconfig rpcbind on
    service nfs start
    chkconfig nfs on

    mkdir -p $NFS_SERVER_PRIMARY
    mkdir -p $NFS_SERVER_SECONDARY
    echo "$NFS_SERVER_PRIMARY   *(rw,async,no_root_squash)" >  /etc/exports
    echo "$NFS_SERVER_SECONDARY *(rw,async,no_root_squash)" >> /etc/exports
    exportfs -a

    echo "Domain = $DOMAIN" >> /etc/idmapd.conf

    echo "LOCKD_TCPPORT=32803
LOCKD_UDPPORT=32769
MOUNTD_PORT=892
RQUOTAD_PORT=875
STATD_PORT=662
STATD_OUTGOING_PORT=2020" >> /etc/sysconfig/nfs

    INPUT_SECTION_LINE=`cat -n /etc/sysconfig/iptables | egrep -- '-A INPUT' | head -1 | awk '{print $1}'`

    head -`expr $INPUT_SECTION_LINE - 1` /etc/sysconfig/iptables > /tmp/before
    tail -$INPUT_SECTION_LINE /etc/sysconfig/iptables > /tmp/after
    cat /tmp/before > /etc/sysconfig/iptables
    echo "-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 111   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 111   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 2049  -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 32803 -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 32769 -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 892   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 892   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 875   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 875   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 662   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 662   -j ACCEPT" >> /etc/sysconfig/iptables
    cat /tmp/after >> /etc/sysconfig/iptables
    rm -rf /tmp/before /tmp/after

    service iptables restart
    service iptables save
}

if [ $# -eq 0 ]
then
    OPT_ERROR=1
fi

while getopts "acnmhr" flag; do
    case $flag in
    \?) OPT_ERROR=1; break;;
    h) OPT_ERROR=1; break;;
    a) opt_agent=true;;
    c) opt_common=true;;
    n) opt_nfs=true;;
    m) opt_management=true;;
    r) opt_reboot=true;;
    esac
done

shift $(( $OPTIND - 1 ))

if [ $OPT_ERROR ]
then
    echo >&2 "usage: $0 [-cnamhr]
  -c : install common packages
  -n : install nfs server
  -a : install cloud agent
  -m : install management server
  -h : show this help
  -r : reboot after installation"
    exit 1
fi

if [ "$opt_agent" = "true" ]
then
    get_network_info
fi
if [ "$opt_nfs" = "true" ]
then
    get_nfs_network
fi
if [ "$opt_management" = "true" ]
then
    get_nfs_info
fi


if [ "$opt_common" = "true" ]
then
    add_ssh_public_key
    install_common
fi
if [ "$opt_agent" = "true" ]
then
    install_agent
fi
if [ "$opt_nfs" = "true" ]
then
    install_nfs
fi
if [ "$opt_management" = "true" ]
then
    install_management
    initialize_storage
fi
if [ "$opt_reboot" = "true" ]
then
    rm -f /usr/share/cloudstack-management/webapps/client/WEB-INF/classes/ehcache.xml
    sync
    sync
    sync
    reboot
fi
