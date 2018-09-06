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
subscription-manager repos --enable=rhel-7-server-ansible-2-rpms

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
    runuser -c "ssh-keygen -t rsa -f /home/$adminUsername/.ssh/id_rsa -q -P ''" - $adminUsername
    touch /home/$adminUsername/.ssh/config
    echo 'Host *' >> /home/$adminUsername/.ssh/config
    echo 'StrictHostKeyChecking no' >> /home/$adminUsername/.ssh/config
    chmod 400 /home/$adminUsername/.ssh/config
    chown $adminUsername:$adminUsername /home/$adminUsername/.ssh/config
    cp ssh_copy_id.exp /home/$adminUsername 
    chown $adminUsername:$adminUsername /home/$adminUsername/ssh_copy_id.exp 
    chmod 777 /home/$adminUsername/ssh_copy_id.exp


index=1    
    while [ $index -le $(($NODECOUNT)) ]; do    
        #runuser -u $adminUsername /home/$adminUsername/ssh_copy_id.exp $adminUsername $PEERNODEPREFIX$index.$DNSsuffix $adminPassword
        #sshpass -p $adminPassword ssh-copy-id -i /home/$adminUsername/.ssh/id_rsa -o "StrictHostKeyChecking no" -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'mkdir /home/'$adminUsername'/.ssh && chmod 700 /home/'$adminUsername'/.ssh'
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'touch /home/'$adminUsername'/.ssh/config'
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'echo "Host *" >  /home/'$adminUsername'/.ssh/config'
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'echo "StrictHostKeyChecking no" >> /home/'$adminUsername'/.ssh/config'
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'chmod 400 /home/'$adminUsername'/.ssh/config'
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'chown '$adminUsername:$adminUsername' /home/'$adminUsername'/.ssh/config'
        cat /home/$adminUsername/.ssh/id_rsa.pub | sshpass -p $adminPassword ssh -o ConnectTimeout=2  $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'cat >> /home/'$adminUsername'/.ssh/authorized_keys'
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'chmod 700 /home/'$adminUsername'/.ssh/'
        sshpass -p $adminPassword ssh -o ConnectTimeout=2 $adminUsername@$PEERNODEPREFIX$index.$DNSsuffix 'chmod 640 /home/'$adminUsername'/.ssh/authorized_keys'
        
        let index++
    done
}

edit_hosts_file() {
    echo " " >> /etc/ansible/hosts
    DNSsuffix=$(nslookup `hostname` | grep Name | cut -f 2 | cut -d "." -f 2-)
    echo "[tendrl-server]" >> /etc/ansible/hosts
    echo "`hostname`.$DNSsuffix ansible_user=$adminUsername" >> /etc/ansible/hosts
    echo " " >> /etc/ansible/hosts
    echo "[gluster-servers]" >> /etc/ansible/hosts
    index=1    
    while [ $index -le $(($NODECOUNT)) ]; do    
        echo "$PEERNODEPREFIX$index.$DNSsuffix ansible_user=$adminUsername" >> /etc/ansible/hosts
        let index++
    done

}

format_disks
install_tendrl
open_ports
configure_ssh
edit_hosts_file

# copy site.yml
# run the playbook
