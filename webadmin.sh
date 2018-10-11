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
GLUSTERVOLUME=${7}

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
# subscription-manager repos --enable=rhel-7-server-ansible-2-rpms
subscription-manager repos --disable=rhel-7-server-ansible-2-rpms
subscription-manager repos --enable=rhel-7-server-ansible-2.6-rpms
# yum downgrade ansible-2.6.5-1.el7ae


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


configure_ssh() {
    
    yum -y install sshpass
    DNSsuffix=$(nslookup `hostname` | grep Name | cut -f 2 | cut -d "." -f 2-)
    su -c "ssh-keygen -t rsa -f /home/$adminUsername/.ssh/id_rsa -q -P ''" - $adminUsername
    SSHCOMMAND="su -c 'sshpass -p $adminPassword ssh-copy-id -i /home/$adminUsername/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=2 $adminUsername@`hostname`.$DNSsuffix -p 22' - $adminUsername"
    eval $SSHCOMMAND
    index=1    
    while [ $index -le $(($NODECOUNT)) ]; do
        SSHCOMMAND="su -c 'sshpass -p $adminPassword ssh-copy-id -i /home/$adminUsername/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix -p 22' - $adminUsername"
        eval $SSHCOMMAND 
        let index++
    done
}

edit_inventory_file() {
    cp /etc/ansible/hosts /home/$adminUsername/inventory
    chown $adminUsername:$adminUsername /home/$adminUsername/inventory
    echo " " >> /home/$adminUsername/inventory
    DNSsuffix=$(nslookup `hostname` | grep Name | cut -f 2 | cut -d "." -f 2-)
    echo "[tendrl_server]" >> /home/$adminUsername/inventory
    echo "`hostname`.$DNSsuffix ansible_user=$adminUsername" >> /home/$adminUsername/inventory
    echo " " >> /home/$adminUsername/inventory
    echo "[gluster_servers]" >> /home/$adminUsername/inventory
    index=1    
    while [ $index -le $(($NODECOUNT)) ]; do    
        echo "$PEERNODEPREFIX$index.$DNSsuffix ansible_user=$adminUsername" >> /home/$adminUsername/inventory
        let index++
    done
    echo " " >> /home/$adminUsername/inventory
    echo "[all:vars]" >> /home/$adminUsername/inventory
    echo "etcd_ip_address=`hostname -I`" >> /home/$adminUsername/inventory
    echo "etcd_fqdn=`hostname`.$DNSsuffix" >> /home/$adminUsername/inventory
    echo "graphite_fqdn=`hostname`.$DNSsuffix" >> /home/$adminUsername/inventory

}


run_ansible_playbook() {
    # copy site.yml
    cp /usr/share/doc/tendrl-ansible-1.6.3/site.yml /home/$adminUsername
    chown $adminUsername:$adminUsername /home/$adminUsername/site.yml

    # run the playbook
    cd /home/$adminUsername
    su -c 'ansible-playbook -b -i inventory site.yml' - $adminUsername

}

install_client() {

    subscription-manager repos --enable=rh-gluster-3-client-for-rhel-7-server-rpms
    yum -y install glusterfs glusterfs-fuse

MOUNTPOINT=/mnt/${GLUSTERVOLUME}
mkdir -p ${MOUNTPOINT}

#Build list of servers
GFSSERVER=$((1 + RANDOM % 7 ))
backupNodes="${PEERNODEPREFIX}${NODECOUNT}"
index=1
while [ $index -lt ${NODECOUNT} ] ; do
    if [ ${index} -ne ${GFSSERVER} ];
        then
        backupNodes="${backupNodes}:${PEERNODEPREFIX}${index}"
    fi
    let index++
done

# Mount the file system and add the /etc/fstab setting

mount -t glusterfs -o backup-volfile-servers=${backupNodes} ${PEERNODEPREFIX}${GFSSERVER}:/${GLUSTERVOLUME} ${MOUNTPOINT}

LINE="${PEERNODEPREFIX}${GFSSERVER}:/${GLUSTERVOLUME} ${MOUNTPOINT} glusterfs defaults,backup-volfile-servers=${backupNodes} 0 0"    
echo -e "${LINE}" >> /etc/fstab


chmod -R 777 $MOUNTPOINT

}

# enable passwordless sudo
sed --in-place 's/ALL=(ALL)\s\+ALL/ALL=(ALL)  NOPASSWD: ALL/' /etc/sudoers.d/waagent


format_disks
install_tendrl
open_ports
configure_ssh
edit_inventory_file
run_ansible_playbook
install_client 
