#!/bin/bash
set -x

#disable_selinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/I' /etc/selinux/config
setenforce 0

adminUsername=${1}
adminPassword=${2}
PEERNODEPREFIX=${3}
NODECOUNT=${4}
USERNAME_ORG=${5}
PASSWORD_ACT_KEY="${6}"

# Remove RHUI

rm -f /etc/yum.repos.d/rh-cloud.repo
sleep 10

# Register Host with Cloud Access Subscription
echo $(date) " - Register host with Cloud Access Subscription"

subscription-manager register --username="$USERNAME_ORG" --password="$PASSWORD_ACT_KEY" --auto-attach --force || subscription-manager register --activationkey="$PASSWORD_ACT_KEY" --org="$USERNAME_ORG" --auto-attach  --force

if [ $? -eq 0 ]
then
    echo "Subscribed successfully"
elif [ $? -eq 64 ]
then
    echo "This system is already registered."
else
    echo "Incorrect Username / Password or Organization ID / Activation Key specified"
    exit 3
fi

install_tendrl() {

subscription-manager attach --pool=8a85f9875f7334a1015f74b57adf779e
subscription-manager repos --disable="*" 
subscription-manager repos --enable=rhel-7-server-rpms
subscription-manager repos --enable=rh-gluster-3-web-admin-server-for-rhel-7-server-rpms

yum -y install ansible tendrl-ansible

}

open_ports() {
   
    firewall-cmd --permanent --zone=public --add-port=2379/tcp
    firewall-cmd --permanent --zone=public --add-port=2003/tcp
    firewall-cmd --permanent --zone=public --add-port=10080/tcp
    firewall-cmd --permanent --zone=public --add-service=http
    firewall-cmd --permanent --zone=public --add-port=9292/tcp
    firewall-cmd --permanent --zone=public --add-port=3000/tcp
    firewall-cmd --permanent --zone=public --add-port=8789/tcp   
    firewall-cmd --reload
}

format_disks() {
fdisk /dev/sdc << EOF
n
p
1


t
83
w
EOF

mkfs -t ext4 /dev/sdc1
mkdir -p /var/lib/etcd
echo "/dev/sdc1 /var/lib/etcd ext4 defaults,nofail 0 2" >> /etc/fstab


fdisk /dev/sdd << EOF
n
p
1


t
83
w
EOF

mkfs -t ext4 /dev/sdd1
mkdir -p /var/lib/carbon
echo "/dev/sdd1 /var/lib/carbon ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

}

#edit /etc/ansible/hosts
# copy site.yml
# run the playbook



configure_ssh() {
    DNSsuffix=$(nslookup `hostname` | grep Name | cut -f 2 | cut -d "." -f 2-)

runuser 
ssh-copy-id sroach@glusterVM4

}

format_disks
install_tendrl
open_ports
#configure_ssh


# edit /etc/ansible/hosts
# copy site.yml
# run the playbook
