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
    
    index=1 
    while [ $index -le $(($GLUSTERDISKCOUNT)) ]; do
        GLUSTERDIR="${MOUNTPOINT}${index}/brick${index}"
        mkdir "${GLUSTERDIR}"
        let index++
    done;

    if [ ${ARBITERHOST} -eq 0 ];
    then   
        index=1 
        while [ $index -le $(($GLUSTERDISKCOUNT)) ]; do
            ARBITERDIR="${ARBITERMOUNTPOINT}${index}/arbiter${index}"
            mkdir "${ARBITERDIR}"
            let index++
        done;
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

gluster volume create ${VOLUMENAME} replica 3 arbiter 1 transport tcp \
${PEERNODEPREFIX}1:/datadrive1/brick1 ${PEERNODEPREFIX}2:/datadrive1/brick1 ${PEERNODEPREFIX}4:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}3:/datadrive1/brick1 ${PEERNODEPREFIX}4:/datadrive1/brick1 ${PEERNODEPREFIX}2:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}1:/datadrive2/brick2 ${PEERNODEPREFIX}2:/datadrive2/brick2 ${PEERNODEPREFIX}4:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}3:/datadrive2/brick2 ${PEERNODEPREFIX}4:/datadrive2/brick2 ${PEERNODEPREFIX}2:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}1:/datadrive3/brick3 ${PEERNODEPREFIX}2:/datadrive3/brick3 ${PEERNODEPREFIX}4:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}3:/datadrive3/brick3 ${PEERNODEPREFIX}4:/datadrive3/brick3 ${PEERNODEPREFIX}2:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}1:/datadrive4/brick4 ${PEERNODEPREFIX}2:/datadrive4/brick4 ${PEERNODEPREFIX}4:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}3:/datadrive4/brick4 ${PEERNODEPREFIX}4:/datadrive4/brick4 ${PEERNODEPREFIX}2:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}1:/datadrive5/brick5 ${PEERNODEPREFIX}2:/datadrive5/brick5 ${PEERNODEPREFIX}4:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}3:/datadrive5/brick5 ${PEERNODEPREFIX}4:/datadrive5/brick5 ${PEERNODEPREFIX}2:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}1:/datadrive6/brick6 ${PEERNODEPREFIX}6:/datadrive6/brick6 ${PEERNODEPREFIX}4:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}3:/datadrive6/brick6 ${PEERNODEPREFIX}6:/datadrive6/brick6 ${PEERNODEPREFIX}2:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}1:/datadrive7/brick7 ${PEERNODEPREFIX}2:/datadrive7/brick7 ${PEERNODEPREFIX}4:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}3:/datadrive7/brick7 ${PEERNODEPREFIX}4:/datadrive7/brick7 ${PEERNODEPREFIX}2:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}1:/datadrive8/brick8 ${PEERNODEPREFIX}2:/datadrive8/brick8 ${PEERNODEPREFIX}4:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}3:/datadrive8/brick8 ${PEERNODEPREFIX}4:/datadrive8/brick8 ${PEERNODEPREFIX}2:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}1:/datadrive9/brick9 ${PEERNODEPREFIX}2:/datadrive9/brick9 ${PEERNODEPREFIX}4:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}3:/datadrive9/brick9 ${PEERNODEPREFIX}4:/datadrive9/brick9 ${PEERNODEPREFIX}2:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}1:/datadrive10/brick10 ${PEERNODEPREFIX}2:/datadrive10/brick10 ${PEERNODEPREFIX}4:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}3:/datadrive10/brick10 ${PEERNODEPREFIX}4:/datadrive10/brick10 ${PEERNODEPREFIX}2:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}1:/datadrive11/brick11 ${PEERNODEPREFIX}2:/datadrive11/brick11 ${PEERNODEPREFIX}4:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}3:/datadrive11/brick11 ${PEERNODEPREFIX}4:/datadrive11/brick11 ${PEERNODEPREFIX}2:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}1:/datadrive12/brick12 ${PEERNODEPREFIX}2:/datadrive12/brick12 ${PEERNODEPREFIX}4:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}3:/datadrive12/brick12 ${PEERNODEPREFIX}4:/datadrive12/brick12 ${PEERNODEPREFIX}2:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}1:/datadrive13/brick13 ${PEERNODEPREFIX}2:/datadrive13/brick13 ${PEERNODEPREFIX}4:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}3:/datadrive13/brick13 ${PEERNODEPREFIX}4:/datadrive13/brick13 ${PEERNODEPREFIX}2:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}1:/datadrive14/brick14 ${PEERNODEPREFIX}2:/datadrive14/brick14 ${PEERNODEPREFIX}4:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}3:/datadrive14/brick14 ${PEERNODEPREFIX}4:/datadrive14/brick14 ${PEERNODEPREFIX}2:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}1:/datadrive15/brick15 ${PEERNODEPREFIX}2:/datadrive15/brick15 ${PEERNODEPREFIX}4:/arbiterdrive15/arbiter15 \
${PEERNODEPREFIX}3:/datadrive15/brick15 ${PEERNODEPREFIX}4:/datadrive15/brick15 ${PEERNODEPREFIX}2:/arbiterdrive15/arbiter15 \
${PEERNODEPREFIX}5:/datadrive1/brick1 ${PEERNODEPREFIX}6:/datadrive1/brick1 ${PEERNODEPREFIX}8:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}7:/datadrive1/brick1 ${PEERNODEPREFIX}8:/datadrive1/brick1 ${PEERNODEPREFIX}6:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}5:/datadrive2/brick2 ${PEERNODEPREFIX}6:/datadrive2/brick2 ${PEERNODEPREFIX}8:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}7:/datadrive2/brick2 ${PEERNODEPREFIX}8:/datadrive2/brick2 ${PEERNODEPREFIX}6:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}5:/datadrive3/brick3 ${PEERNODEPREFIX}6:/datadrive3/brick3 ${PEERNODEPREFIX}8:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}7:/datadrive3/brick3 ${PEERNODEPREFIX}8:/datadrive3/brick3 ${PEERNODEPREFIX}6:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}5:/datadrive4/brick4 ${PEERNODEPREFIX}6:/datadrive4/brick4 ${PEERNODEPREFIX}8:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}7:/datadrive4/brick4 ${PEERNODEPREFIX}8:/datadrive4/brick4 ${PEERNODEPREFIX}6:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}5:/datadrive5/brick5 ${PEERNODEPREFIX}6:/datadrive5/brick5 ${PEERNODEPREFIX}8:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}7:/datadrive5/brick5 ${PEERNODEPREFIX}8:/datadrive5/brick5 ${PEERNODEPREFIX}6:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}5:/datadrive6/brick6 ${PEERNODEPREFIX}6:/datadrive6/brick6 ${PEERNODEPREFIX}8:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}7:/datadrive6/brick6 ${PEERNODEPREFIX}8:/datadrive6/brick6 ${PEERNODEPREFIX}6:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}5:/datadrive7/brick7 ${PEERNODEPREFIX}6:/datadrive7/brick7 ${PEERNODEPREFIX}8:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}7:/datadrive7/brick7 ${PEERNODEPREFIX}8:/datadrive7/brick7 ${PEERNODEPREFIX}6:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}5:/datadrive8/brick8 ${PEERNODEPREFIX}6:/datadrive8/brick8 ${PEERNODEPREFIX}8:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}7:/datadrive8/brick8 ${PEERNODEPREFIX}8:/datadrive8/brick8 ${PEERNODEPREFIX}6:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}5:/datadrive9/brick9 ${PEERNODEPREFIX}6:/datadrive9/brick9 ${PEERNODEPREFIX}8:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}7:/datadrive9/brick9 ${PEERNODEPREFIX}8:/datadrive9/brick9 ${PEERNODEPREFIX}6:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}5:/datadrive10/brick10 ${PEERNODEPREFIX}6:/datadrive10/brick10 ${PEERNODEPREFIX}8:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}7:/datadrive10/brick10 ${PEERNODEPREFIX}8:/datadrive10/brick10 ${PEERNODEPREFIX}6:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}5:/datadrive11/brick11 ${PEERNODEPREFIX}6:/datadrive11/brick11 ${PEERNODEPREFIX}8:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}7:/datadrive11/brick11 ${PEERNODEPREFIX}8:/datadrive11/brick11 ${PEERNODEPREFIX}6:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}5:/datadrive12/brick12 ${PEERNODEPREFIX}6:/datadrive12/brick12 ${PEERNODEPREFIX}8:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}7:/datadrive12/brick12 ${PEERNODEPREFIX}8:/datadrive12/brick12 ${PEERNODEPREFIX}6:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}5:/datadrive13/brick13 ${PEERNODEPREFIX}6:/datadrive13/brick13 ${PEERNODEPREFIX}8:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}7:/datadrive13/brick13 ${PEERNODEPREFIX}8:/datadrive13/brick13 ${PEERNODEPREFIX}6:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}5:/datadrive14/brick14 ${PEERNODEPREFIX}6:/datadrive14/brick14 ${PEERNODEPREFIX}8:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}7:/datadrive14/brick14 ${PEERNODEPREFIX}8:/datadrive14/brick14 ${PEERNODEPREFIX}6:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}5:/datadrive15/brick15 ${PEERNODEPREFIX}6:/datadrive15/brick15 ${PEERNODEPREFIX}8:/arbiterdrive15/arbiter15 \
${PEERNODEPREFIX}7:/datadrive15/brick15 ${PEERNODEPREFIX}8:/datadrive15/brick15 ${PEERNODEPREFIX}6:/arbiterdrive15/arbiter15 \
${PEERNODEPREFIX}9:/datadrive1/brick1 ${PEERNODEPREFIX}10:/datadrive1/brick1 ${PEERNODEPREFIX}12:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}11:/datadrive1/brick1 ${PEERNODEPREFIX}12:/datadrive1/brick1 ${PEERNODEPREFIX}10:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}9:/datadrive2/brick2 ${PEERNODEPREFIX}10:/datadrive2/brick2 ${PEERNODEPREFIX}12:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}11:/datadrive2/brick2 ${PEERNODEPREFIX}12:/datadrive2/brick2 ${PEERNODEPREFIX}10:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}9:/datadrive3/brick3 ${PEERNODEPREFIX}10:/datadrive3/brick3 ${PEERNODEPREFIX}12:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}11:/datadrive3/brick3 ${PEERNODEPREFIX}12:/datadrive3/brick3 ${PEERNODEPREFIX}10:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}9:/datadrive4/brick4 ${PEERNODEPREFIX}10:/datadrive4/brick4 ${PEERNODEPREFIX}12:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}11:/datadrive4/brick4 ${PEERNODEPREFIX}12:/datadrive4/brick4 ${PEERNODEPREFIX}10:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}9:/datadrive5/brick5 ${PEERNODEPREFIX}10:/datadrive5/brick5 ${PEERNODEPREFIX}12:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}11:/datadrive5/brick5 ${PEERNODEPREFIX}12:/datadrive5/brick5 ${PEERNODEPREFIX}10:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}9:/datadrive6/brick6 ${PEERNODEPREFIX}10:/datadrive6/brick6 ${PEERNODEPREFIX}12:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}11:/datadrive6/brick6 ${PEERNODEPREFIX}12:/datadrive6/brick6 ${PEERNODEPREFIX}10:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}9:/datadrive7/brick7 ${PEERNODEPREFIX}10:/datadrive7/brick7 ${PEERNODEPREFIX}12:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}11:/datadrive7/brick7 ${PEERNODEPREFIX}12:/datadrive7/brick7 ${PEERNODEPREFIX}10:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}9:/datadrive8/brick8 ${PEERNODEPREFIX}10:/datadrive8/brick8 ${PEERNODEPREFIX}12:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}11:/datadrive8/brick8 ${PEERNODEPREFIX}12:/datadrive8/brick8 ${PEERNODEPREFIX}10:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}9:/datadrive9/brick9 ${PEERNODEPREFIX}10:/datadrive9/brick9 ${PEERNODEPREFIX}12:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}11:/datadrive9/brick9 ${PEERNODEPREFIX}12:/datadrive9/brick9 ${PEERNODEPREFIX}10:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}9:/datadrive10/brick10 ${PEERNODEPREFIX}10:/datadrive10/brick10 ${PEERNODEPREFIX}12:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}11:/datadrive10/brick10 ${PEERNODEPREFIX}12:/datadrive10/brick10 ${PEERNODEPREFIX}10:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}9:/datadrive11/brick11 ${PEERNODEPREFIX}10:/datadrive11/brick11 ${PEERNODEPREFIX}12:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}11:/datadrive11/brick11 ${PEERNODEPREFIX}12:/datadrive11/brick11 ${PEERNODEPREFIX}10:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}9:/datadrive12/brick12 ${PEERNODEPREFIX}10:/datadrive12/brick12 ${PEERNODEPREFIX}12:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}11:/datadrive12/brick12 ${PEERNODEPREFIX}12:/datadrive12/brick12 ${PEERNODEPREFIX}10:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}9:/datadrive13/brick13 ${PEERNODEPREFIX}10:/datadrive13/brick13 ${PEERNODEPREFIX}12:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}11:/datadrive13/brick13 ${PEERNODEPREFIX}12:/datadrive13/brick13 ${PEERNODEPREFIX}10:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}9:/datadrive14/brick14 ${PEERNODEPREFIX}10:/datadrive14/brick14 ${PEERNODEPREFIX}12:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}11:/datadrive14/brick14 ${PEERNODEPREFIX}12:/datadrive14/brick14 ${PEERNODEPREFIX}10:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}9:/datadrive15/brick15 ${PEERNODEPREFIX}10:/datadrive15/brick15 ${PEERNODEPREFIX}12:/arbiterdrive15/arbiter15 \
${PEERNODEPREFIX}11:/datadrive15/brick15 ${PEERNODEPREFIX}12:/datadrive15/brick15 ${PEERNODEPREFIX}10:/arbiterdrive15/arbiter15 \
${PEERNODEPREFIX}13:/datadrive1/brick1 ${PEERNODEPREFIX}14:/datadrive1/brick1 ${PEERNODEPREFIX}16:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}15:/datadrive1/brick1 ${PEERNODEPREFIX}16:/datadrive1/brick1 ${PEERNODEPREFIX}14:/arbiterdrive1/arbiter1 \
${PEERNODEPREFIX}13:/datadrive2/brick2 ${PEERNODEPREFIX}14:/datadrive2/brick2 ${PEERNODEPREFIX}16:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}15:/datadrive2/brick2 ${PEERNODEPREFIX}16:/datadrive2/brick2 ${PEERNODEPREFIX}14:/arbiterdrive2/arbiter2 \
${PEERNODEPREFIX}13:/datadrive3/brick3 ${PEERNODEPREFIX}14:/datadrive3/brick3 ${PEERNODEPREFIX}16:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}15:/datadrive3/brick3 ${PEERNODEPREFIX}16:/datadrive3/brick3 ${PEERNODEPREFIX}14:/arbiterdrive3/arbiter3 \
${PEERNODEPREFIX}13:/datadrive4/brick4 ${PEERNODEPREFIX}14:/datadrive4/brick4 ${PEERNODEPREFIX}16:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}15:/datadrive4/brick4 ${PEERNODEPREFIX}16:/datadrive4/brick4 ${PEERNODEPREFIX}14:/arbiterdrive4/arbiter4 \
${PEERNODEPREFIX}13:/datadrive5/brick5 ${PEERNODEPREFIX}14:/datadrive5/brick5 ${PEERNODEPREFIX}16:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}15:/datadrive5/brick5 ${PEERNODEPREFIX}16:/datadrive5/brick5 ${PEERNODEPREFIX}14:/arbiterdrive5/arbiter5 \
${PEERNODEPREFIX}13:/datadrive6/brick6 ${PEERNODEPREFIX}14:/datadrive6/brick6 ${PEERNODEPREFIX}16:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}15:/datadrive6/brick6 ${PEERNODEPREFIX}16:/datadrive6/brick6 ${PEERNODEPREFIX}14:/arbiterdrive6/arbiter6 \
${PEERNODEPREFIX}13:/datadrive7/brick7 ${PEERNODEPREFIX}14:/datadrive7/brick7 ${PEERNODEPREFIX}16:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}15:/datadrive7/brick7 ${PEERNODEPREFIX}16:/datadrive7/brick7 ${PEERNODEPREFIX}14:/arbiterdrive7/arbiter7 \
${PEERNODEPREFIX}13:/datadrive8/brick8 ${PEERNODEPREFIX}14:/datadrive8/brick8 ${PEERNODEPREFIX}16:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}15:/datadrive8/brick8 ${PEERNODEPREFIX}16:/datadrive8/brick8 ${PEERNODEPREFIX}14:/arbiterdrive8/arbiter8 \
${PEERNODEPREFIX}13:/datadrive9/brick9 ${PEERNODEPREFIX}14:/datadrive9/brick9 ${PEERNODEPREFIX}16:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}15:/datadrive9/brick9 ${PEERNODEPREFIX}16:/datadrive9/brick9 ${PEERNODEPREFIX}14:/arbiterdrive9/arbiter9 \
${PEERNODEPREFIX}13:/datadrive10/brick10 ${PEERNODEPREFIX}14:/datadrive10/brick10 ${PEERNODEPREFIX}16:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}15:/datadrive10/brick10 ${PEERNODEPREFIX}16:/datadrive10/brick10 ${PEERNODEPREFIX}14:/arbiterdrive10/arbiter10 \
${PEERNODEPREFIX}13:/datadrive11/brick11 ${PEERNODEPREFIX}14:/datadrive11/brick11 ${PEERNODEPREFIX}16:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}15:/datadrive11/brick11 ${PEERNODEPREFIX}16:/datadrive11/brick11 ${PEERNODEPREFIX}14:/arbiterdrive11/arbiter11 \
${PEERNODEPREFIX}13:/datadrive12/brick12 ${PEERNODEPREFIX}14:/datadrive12/brick12 ${PEERNODEPREFIX}16:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}15:/datadrive12/brick12 ${PEERNODEPREFIX}16:/datadrive12/brick12 ${PEERNODEPREFIX}14:/arbiterdrive12/arbiter12 \
${PEERNODEPREFIX}13:/datadrive13/brick13 ${PEERNODEPREFIX}14:/datadrive13/brick13 ${PEERNODEPREFIX}16:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}15:/datadrive13/brick13 ${PEERNODEPREFIX}16:/datadrive13/brick13 ${PEERNODEPREFIX}14:/arbiterdrive13/arbiter13 \
${PEERNODEPREFIX}13:/datadrive14/brick14 ${PEERNODEPREFIX}14:/datadrive14/brick14 ${PEERNODEPREFIX}16:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}15:/datadrive14/brick14 ${PEERNODEPREFIX}16:/datadrive14/brick14 ${PEERNODEPREFIX}14:/arbiterdrive14/arbiter14 \
${PEERNODEPREFIX}13:/datadrive15/brick15 ${PEERNODEPREFIX}14:/datadrive15/brick15 ${PEERNODEPREFIX}16:/arbiterdrive15/arbiter15 \
${PEERNODEPREFIX}15:/datadrive15/brick15 ${PEERNODEPREFIX}16:/datadrive15/brick15 ${PEERNODEPREFIX}14:/arbiterdrive15/arbiter15 \



    #gluster volume create ${VOLUMENAME} replica 2 transport tcp ${allNodes} 2>> /tmp/error << EOF
#y
#EOF
    
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
