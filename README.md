# Gluster File System
Automated deployment of gluster servers and clients

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgrandparoach%2Fgluster%2FEDA%2Fazuredeploy.json" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>

This template lets you create an N node Gluster File System on RHEL 7.5. You can provision 2, 4, 6, or 8 nodes in an arbitrated-replicated cluster with a replication factor of 2. These machines will be placed into the same Availability Set.  There are no public IP addresses, so it must be installed onto an existing Virtual Network.  The number and size of the attached disks are specified as input parameters.  Each of the attached disks will be configured as a gluster data brick.  The even numbered hosts will have an additional attached drive which will be carved into multiple Logical Volumes for the arbiter bricks.  NFS is disabled, so all the clients must use the gluster native fuse client to access the file system.

This template will also provision a separate Machine for running the Gluster Web Administration tools.  This machine will have a public IP address which host the web Admin tools from a browser.  This machine can also serve as the jump box for accessing the Gluster server nodes via ssh.  

The settings for these servers have been adopted from the guidance mentioned in this eBook  https://azure.microsoft.com/mediahandler/files/resourcefiles/parallel-virtual-file-systems-on-microsoft-azure/Parallel_Virtual_File_Systems_on_Microsoft_Azure.pdf 


This link will deploy a cluster of client machines for testing the gluster servers performance.

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgrandparoach%2Fgluster%2FEDA%2Fgluster_client.json" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>
lso
