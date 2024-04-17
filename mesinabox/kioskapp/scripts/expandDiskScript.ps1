df -H 
lvextend -L+1G /dev/mapper/rhel-root
xfs_growfs /
df -H 