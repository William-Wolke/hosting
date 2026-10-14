My config for fstab and hetzner where you would need to change the uid,gid and username
username@username.your-storagebox.de:/home /mnt/storage-box-1 fuse.sshfs port=23,IdentityFile=/root/.ssh/storagebox,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,allow_other,default_permissions,uid=1000,gid=1000,_netdev,nofail 0 0

I needed to install fuse and sshfs
```
sudo apt install fuse sshfs
```

Also since root needs a key you can create one
```shell
sudo ssh-keygen -t ed25519 -f /root/.ssh/storagebox -N ""
```

And then copy to the storage box, change username here
```shell
sudo cat /root/.ssh/storagebox.pub | ssh -p 23 username@username.your-storagebox.de install-ssh-key
```
