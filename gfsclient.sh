#!/bin/bash

set -x

GLUSTERHOSTPREFIX=${1}
GLUSTERHOSTCOUNT=${2}
GLUSTERVOLUME=${3}

LOGINSERVER=${4}

# Shares
SHARE_HOME=/share/home
mkdir -p /share
mkdir -p $SHARE_HOME

# User
HPC_USER=hpcuser
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007

MOUNTPOINT=/mnt/${GLUSTERVOLUME}
mkdir -p ${MOUNTPOINT}

yum -y install nfs-utils nfs-utils-lib

#Install Gluster Fuse Client

yum -y install psmisc

wget --no-cache https://buildlogs.centos.org/centos/7/storage/x86_64/gluster-4.1/glusterfs-libs-4.1.1-1.el7.x86_64.rpm
rpm -i glusterfs-libs-4.1.1-1.el7.x86_64.rpm
wget --no-cache https://buildlogs.centos.org/centos/7/storage/x86_64/gluster-4.1/glusterfs-4.1.1-1.el7.x86_64.rpm
rpm -i glusterfs-4.1.1-1.el7.x86_64.rpm
wget https://buildlogs.centos.org/centos/7/storage/x86_64/gluster-4.1/glusterfs-client-xlators-4.1.1-1.el7.x86_64.rpm
rpm -i glusterfs-client-xlators-4.1.1-1.el7.x86_64.rpm
wget https://buildlogs.centos.org/centos/7/storage/x86_64/gluster-4.1/glusterfs-fuse-4.1.1-1.el7.x86_64.rpm
rpm -i glusterfs-fuse-4.1.1-1.el7.x86_64.rpm

#Build list of servers

index=1
backupNodes="${GLUSTERHOSTPREFIX}${index}"
let index++
while [ $index -lt ${GLUSTERHOSTCOUNT} ] ; do
    backupNodes="${backupNodes}:${GLUSTERHOSTPREFIX}${index}"
    let index++
done

# Mount the file system and add the /etc/fstab setting

mount -t glusterfs -o backup-volfile-servers=${backupNodes} ${GLUSTERHOSTPREFIX}${GLUSTERHOSTCOUNT}:/${GLUSTERVOLUME} ${MOUNTPOINT}

LINE="${GLUSTERHOSTPREFIX}${GLUSTERHOSTCOUNT}:/${GLUSTERVOLUME} ${MOUNTPOINT} glusterfs defaults,backup-volfile-servers=${backupNodes} 0 0"    
echo -e "${LINE}" >> /etc/fstab

# Install performance test tools

yum -y install gcc gcc-gfortran gcc-c++
mkdir /glustre/software
cd /glustre/software/
wget http://www.mpich.org/static/downloads/3.1.4/mpich-3.1.4.tar.gz
tar xzf mpich-3.1.4.tar.gz
cd mpich-3.1.4
./configure --prefix=/glustre/software/mpich3/
make
make install 

# Update environment variables

export PATH=/glustre/software/mpich3/bin:$PATH
export LD_LIBRARY_PATH=/glustre/software/mpich3/lib:${LD_LIBRARY_PATH}

# Compile IOR

cd /glustre/software/
yum -y install git automake
git clone https://github.com/chaos/ior.git
mv ior ior_src
cd ior_src/
./bootstrap
./configure --prefix=/glustre/software/ior/
make
make install


# disable selinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/I' /etc/selinux/config
setenforce 0


  

	echo "$LOGINSERVER:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
	mount -a
	mount
   
    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

	useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER

    chown $HPC_USER:$HPC_GROUP $SHARE_DATA	



