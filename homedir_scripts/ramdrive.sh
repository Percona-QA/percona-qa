if [ "$(mount | grep -o "ramfs on /mnt/ram")" != "ramfs on /mnt/ram" ]; then
  sudo mkdir -p /ram
  sudo mount -t ramfs -o size=40g ramfs /ram
  sudo chown -R roel /ram
fi
mount | grep ram

# cd ~
# sudo umount /mnt/ram