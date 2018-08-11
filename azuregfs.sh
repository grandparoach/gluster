#!/bin/bash

set -x

USERNAME_ORG=${6}
PASSWORD_ACT_KEY="${7}"

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
PVSIZE=${5}

MOUNTPOINT="/datadrive"
RAIDCHUNKSIZE=128

RAIDDISK="/dev/md127"

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


create_raid0_centos() {
    echo "Creating raid0"
    yes | mdadm --create "$RAIDDISK" --name=data --level=0 --chunk="$RAIDCHUNKSIZE" --raid-devices="$DISKCOUNT" "${DISKS[@]}"
    mdadm --detail --verbose --scan > /etc/mdadm.conf
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
            
    create_raid0_centos
        
    PARTITION="${RAIDDISK}"
    
    echo "Creating filesystem on ${PARTITION}."
     
    mkfs -t ext4 ${PARTITION}
    mkdir -p "${MOUNTPOINT}"

    #add_to_fstab "${UUID}" "${MOUNTPOINT}"
    echo -e "${PARTITION}\t${MOUNTPOINT}\text4\tdefaults,barrier=0,noatime 0 2"  | sudo tee -a /etc/fstab 
    
    echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
    #mount "${MOUNTPOINT}"
    mount -a && mount 
}


open_ports() {
    firewall-cmd --zone=trusted --add-service=glusterfs --permanent
}


disable_selinux_centos() {
    sed -i 's/^SELINUX=.*/SELINUX=disabled/I' /etc/selinux/config
    setenforce 0
}



configure_network() {
    open_ports
    disable_selinux_centos
    
}


install_glusterfs() {

    subscription-manager attach --pool=8a85f9875f7334a1015f74b579f67798
    subscription-manager repos --disable "*"
    subscription-manager repos --enable=rhel-7-server-rpms
    subscription-manager repos --enable=rh-gluster-3-for-rhel-7-server-rpms
    
    yum install redhat-storage-server
    

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
    
    allNodes="${NODENAME}:${GLUSTERDIR}"
    retry=10
    failed=1
    while [ $retry -gt 0 ] && [ $failed -gt 0 ]; do
        failed=0
        index=1
        echo retrying $retry >> /tmp/error
        while [ $index -lt $(($NODECOUNT)) ]; do
            ping -c 3 "${PEERNODEPREFIX}${index}" > /tmp/error
            gluster peer probe "${PEERNODEPREFIX}${index}" >> /tmp/error
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
                allNodes="${allNodes} ${PEERNODEPREFIX}${index}:${GLUSTERDIR}"
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


configure_nagios() {
   
    setsebool -P logging_syslogd_run_nagios_plugins on
    setsebool -P nagios_run_sudo on

    sed -i 's/allowed_hosts=127.0.0.1/allowed_hosts=127.0.0.1, "${PEERNODEPREFIX}${NODECOUNT}"/' /etc/nagios/nrpe.cfg
    service glusterd start
    gluster system:: uuid reset << EOF
y
EOF


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
    
    allNodes="${NODENAME}:${GLUSTERDIR}"
    retry=10
    failed=1
    while [ $retry -gt 0 ] && [ $failed -gt 0 ]; do
    
}

configure_tendrl() {
   
    firewall-cmd --permanent --zone=public --add-port=8697/tcp

    subscription-manager repos --enable=rhel-7-server-rpms --enable=rh-gluster-3-for-rhel-7-server-rpms
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



# temporary workaround form CRP 
allow_passwordssh  


    configure_network
    configure_disks
    configure_gluster


