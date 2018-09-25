#!/bin/bash

set -x

#disable_selinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/I' /etc/selinux/config
setenforce 0


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

NODENAME=$(hostname)
PEERNODEPREFIX=${1}
VOLUMENAME=${2}
NODEINDEX=${3}
NODECOUNT=${4}

MOUNTPOINT="/datadrive"

VGNAME="glusterVG"
LVPOOLNAME="thinpool"
BRICKLV="brickLV"


# An set of disks to ignore from partitioning and formatting
BLACKLIST="/dev/sda|/dev/sdb"

scan_for_new_disks() {
    # Looks for unpartitioned disks
    declare -a RET
    DEVS=($(ls -1 /dev/sd*|egrep -v "${BLACKLIST}"|egrep -v "[0-9]$"))
    for DEV in "${DEVS[@]}";
    do
        # Check each device if there is a "1" partition.  If not,
        # "assume" it is not partitioned.
        if [ ! -b ${DEV}1 ];
        then
            RET+="${DEV} "
        fi
    done
    echo "${RET}"
}

get_disk_count() {
    DISKCOUNT=0
    for DISK in "${DISKS[@]}";
    do 
        DISKCOUNT+=1
    done;
    echo "$DISKCOUNT"
}




do_LVM_partition() {
    
   pvcreate --dataalignment 256K ${DISKS[@]}
   vgcreate ${VGNAME} ${DISKS[@]}
   lvcreate --thin ${VGNAME}/${LVPOOLNAME} --extents 100%FREE --chunksize 256k --poolmetadatasize 16G --zero n
   lvpoolsize=$(lvdisplay | grep Current | rev | cut -d " " -f1 | rev)
   let lvsize=($lvpoolsize * 388 / 100000)
   lvcreate --thin --name ${BRICKLV} --virtualsize "${lvsize}G" ${VGNAME}/${LVPOOLNAME}
 

}



add_to_fstab() {
    UUID=${1}
    MOUNTPOINT=${2}
    grep "${UUID}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${UUID} to fstab again (it's already there!)"
    else
        LINE="UUID=${UUID} ${MOUNTPOINT} ext4 defaults,noatime 0 0"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

configure_disks() {
    ls "${MOUNTPOINT}"
    if [ ${?} -eq 0 ]
    then 
        return
    fi
    DISKS=($(scan_for_new_disks))
    echo "Disks are ${DISKS[@]}"
    declare -i DISKCOUNT
    DISKCOUNT=$(get_disk_count) 
    echo "Disk count is $DISKCOUNT"
            
    
    do_LVM_partition ${DISKS[@]}
    PARTITION="/dev/${VGNAME}/${BRICKLV}"
        
    
    echo "Creating filesystem on ${PARTITION}."
    mkfs.xfs -f -K -i size=512 -n size=8192 ${PARTITION}  

    
    mkdir -p "${MOUNTPOINT}"

    #add_to_fstab "${UUID}" "${MOUNTPOINT}"
    echo -e "${PARTITION}\t${MOUNTPOINT}\txfs\tdefaults,inode64,nobarrier,noatime 0 2"  | sudo tee -a /etc/fstab 
    
    echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
    #mount "${MOUNTPOINT}"
    mount -a && mount 
}


open_ports() {
   
    firewall-cmd --zone=public --add-service=glusterfs --permanent
    firewall-cmd --reload

}




install_glusterfs() {

    subscription-manager attach --pool=8a85f9875f7334a1015f74b579f67798
    subscription-manager repos --disable "*"
    subscription-manager repos --enable=rhel-7-server-rpms
    subscription-manager repos --enable=rh-gluster-3-for-rhel-7-server-rpms
    subscription-manager repos --enable=rhel-7-server-ansible-2-rpms

    
    
    yum -y install redhat-storage-server

    yum -y install gstatus
    
    open_ports

}

configure_gluster() {
   
    install_glusterfs
    service glusterd start
    #gluster system:: uuid reset << EOF
#y
#EOF


    GLUSTERDIR="${MOUNTPOINT}/brick"
    ls "${GLUSTERDIR}"
    if [ ${?} -ne 0 ];
    then
        mkdir "${GLUSTERDIR}"
    fi

    if [ $NODEINDEX -lt $(($NODECOUNT)) ];
    then
        return
    fi
    
    DNSsuffix=$(nslookup `hostname` | grep Name | cut -f 2 | cut -d "." -f 2-)

    allNodes="${NODENAME}.${DNSsuffix}:${GLUSTERDIR}"
    retry=10
    failed=1
    while [ $retry -gt 0 ] && [ $failed -gt 0 ]; do
        failed=0
        index=1
        echo retrying $retry >> /tmp/error
        while [ $index -lt $(($NODECOUNT)) ]; do
            ping -c 3 "${PEERNODEPREFIX}${index}.${DNSsuffix}" > /tmp/error
            gluster peer probe "${PEERNODEPREFIX}${index}.${DNSsuffix}" >> /tmp/error
            if [ ${?} -ne 0 ];
            then
                failed=1
                echo "gluster peer probe ${PEERNODEPREFIX}${index} failed"
            fi
            gluster peer status >> /tmp/error
            gluster peer status | grep "${PEERNODEPREFIX}${index}" >> /tmp/error
            if [ ${?} -ne 0 ];
            then
                failed=1
                echo "gluster peer status ${PEERNODEPREFIX}${index} failed"
            fi
            if [ $retry -eq 10 ]; then
                allNodes="${allNodes} ${PEERNODEPREFIX}${index}.${DNSsuffix}:${GLUSTERDIR}"
            fi
            let index++
        done
        sleep 30
        let retry--
    done

    gluster volume create ${VOLUMENAME} replica 2 transport tcp ${allNodes} 2>> /tmp/error << EOF
y
EOF
    
    gluster volume info 2>> /tmp/error
    gluster volume start ${VOLUMENAME} 2>> /tmp/error

    #Tune for small file improvements
    gluster volume set ${VOLUMENAME} features.cache-invalidation on
    gluster volume set ${VOLUMENAME} features.cache-invalidation-timeout 600
    gluster volume set ${VOLUMENAME} performance.stat-prefetch on
    gluster volume set ${VOLUMENAME} performance.cache-samba-metadata on
    gluster volume set ${VOLUMENAME} performance.cache-invalidation on
    gluster volume set ${VOLUMENAME} performance.md-cache-timeout 600
    gluster volume set ${VOLUMENAME} network.inode-lru-limit 90000

}


configure_tendrl() {

    rm -f /etc/machine-id
    systemd-machine-id-setup

    firewall-cmd --permanent --zone=public --add-port=8697/tcp
    firewall-cmd --reload

    subscription-manager repos --enable=rh-gluster-3-web-admin-agent-for-rhel-7-server-rpms
    
}

allow_passwordssh() {
    grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config
    if [ ${?} -eq 0 ];
    then
        return
    fi
    sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication yes/I" /etc/ssh/sshd_config
    sed -i "s/^PasswordAuthentication no.*/PasswordAuthentication yes/I" /etc/ssh/sshd_config
    
        /etc/init.d/sshd reload
    
}


# enable passwordless sudo
sed --in-place 's/ALL=(ALL)\s\+ALL/ALL=(ALL)  NOPASSWD: ALL/' /etc/sudoers.d/waagent


# temporary workaround form CRP 
allow_passwordssh  

configure_disks
configure_gluster
configure_tendrl
