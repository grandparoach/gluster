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
ARBITERMOUNTPOINT="/arbiterdrive"

VGNAME="glusterVG"
LVPOOLNAME="thinpool"
BRICKLV="brickLV"

ARBITERVGNAME="arbiterVG"
ARBITERPOOLNAME="arbiterthinpool"
ARBITERBRICKLV="arbiterbrickLV"

# Check to see if hostname is odd or even.  
# Even numbered hosts have an extra disk for the arbiter

let ARBITERHOST=( `hostname | sed -s "s/$PEERNODEPREFIX//"` % 2)


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




do_gluster_LVM_partition() {

   index=1 
   while [ $index -le $(($GLUSTERDISKCOUNT)) ]; do
        pvcreate --dataalignment 256K ${DISKS[${index}-1]}
        vgcreate ${VGNAME}${index} ${DISKS[${index}-1]}
        blockname=$(echo ${DISKS[${index}-1]} | cut -d/ -f3)
        disksize=$(lsblk | grep $blockname | awk '{print $4}' | cut -dG -f1)
        let lvsize=($disksize * 96 / 100 )
        lvcreate -L "${lvsize}G" -T ${VGNAME}${index}/${LVPOOLNAME}${index} -V "${lvsize}G" -n ${BRICKLV}${index} --chunksize 256k --zero n
#        lvcreate -L "${lvsize}G" -T ${VGNAME}${index}/${LVPOOLNAME}${index} -V "${lvsize}G" -n ${BRICKLV}${index} --chunksize 256k --poolmetadatasize 16G --zero n ${DISKS[${index}-1]}
        let index++
    done;

}

do_arbiter_LVM_partition() {

    pvcreate --dataalignment 256K ${DISKS[${GLUSTERDISKCOUNT}]}
    vgcreate ${ARBITERVGNAME} ${DISKS[${GLUSTERDISKCOUNT}]}
    lvcreate --thin ${ARBITERVGNAME}/${ARBITERPOOLNAME} --extents 100%FREE --chunksize 256k --zero n
    blockname=$(echo ${DISKS[${GLUSTERDISKCOUNT}]} | cut -d/ -f3)
    disksize=$(lsblk | grep $blockname | awk '{print $4}' | cut -dG -f1)
    let lvsize=($disksize * 96 / 100 / $GLUSTERDISKCOUNT )
    index=1 
    while [ $index -le $(($GLUSTERDISKCOUNT)) ]; do
        lvcreate --thin --name ${ARBITERBRICKLV}${index} --virtualsize "${lvsize}G" ${ARBITERVGNAME}/${ARBITERPOOLNAME}
        let index++
    done;

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
            
    if [ ${ARBITERHOST} -eq 0 ];
    then
        let GLUSTERDISKCOUNT=($DISKCOUNT - 1)
    else
        let GLUSTERDISKCOUNT=$DISKCOUNT
    fi
    
    do_gluster_LVM_partition ${DISKS[@]}

    if [ ${ARBITERHOST} -eq 0 ];
    then
        do_arbiter_LVM_partition ${DISKS[@]}
    fi
    
       
    index=1
    while [ $index -le $GLUSTERDISKCOUNT ]; 
    do 
        PARTITION="/dev/${VGNAME}${index}/${BRICKLV}${index}"
        echo "Creating filesystem on ${PARTITION}."
        mkfs.xfs -f -K -i size=512 -n size=8192 ${PARTITION}
        mkdir -p "${MOUNTPOINT}${index}"
        echo -e "${PARTITION}\t${MOUNTPOINT}${index}\txfs\tdefaults,inode64,nobarrier,noatime 0 2"  | sudo tee -a /etc/fstab 
        let index++
    done;
    
    if [ ${ARBITERHOST} -eq 0 ];
    then
        index=1
        while [ $index -le $GLUSTERDISKCOUNT ]; 
        do 
            PARTITION="/dev/${ARBITERVGNAME}/${ARBITERBRICKLV}${index}"
            echo "Creating filesystem on ${PARTITION}."
            mkfs.xfs -f -K -i size=512 -n size=8192 ${PARTITION}
            mkdir -p "${ARBITERMOUNTPOINT}${index}"
            echo -e "${PARTITION}\t${ARBITERMOUNTPOINT}${index}\txfs\tdefaults,inode64,nobarrier,noatime 0 2"  | sudo tee -a /etc/fstab 
            let index++
    done;  
       
    fi

    echo "Mounting disk ${PARTITION}${index} on ${MOUNTPOINT}${index}"

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
