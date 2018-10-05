# To generate a new PXC main file, do this;
# 1. Pull PXC source, cd into dir
# 2. Run mtr_to_sql.sh in it
# 3. Make a copy like this;  
#    cd ~/percona-qa/pquery; rm -f pxc-main-ms-ps-md.sql; cp main-ms-ps-md.sql pxc-main-ms-ps-md.sql
# 4. Add the generated SQL from PXC 3x into the new file;
#    cat /tmp/mtr_to_sql.sql >> ~/percona-qa/pquery/pxc-main-ms-ps-md.sql  # Repeat 3 times
# 5. Run this script in this directory
#    ./fix_pxc-main.sh

if [ ! -r pxc-main-ms-ps-md.sql ]; then 
  echo "Assert: pxc-main-ms-ps-md.sql not found!"
  exit 1
fi

# Change all engines to InnoDB as this is the only accepted engine in PXB
# Decided to not substitute MEMORY or CSV engines to have some variation
sed -i 's|TokuDB|InnoDB|gi' pxc-main-ms-ps-md.sql
sed -i 's|RocksDB|InnoDB|gi' pxc-main-ms-ps-md.sql
sed -i 's|MyISAM|InnoDB|gi' pxc-main-ms-ps-md.sql
sed -i 's|Maria|InnoDB|gi' pxc-main-ms-ps-md.sql

# Re-shuffle the file (which is necessary) 
RANDOM=$(date +%s%N | cut -b14-19)  # RANDOM: Random entropy pool init
shuf --random-source=/dev/urandom pxc-main-ms-ps-md.sql > /tmp/pxc-main-ms-ps-md.sql.temp

# .tar.xz compress it (the .tar.xz is the only file uploaded to repo)
rm -f ./pxc-main-ms-ps-md.sql.old
mv -f pxc-main-ms-ps-md.sql pxc-main-ms-ps-md.sql.old
mv -f /tmp/pxc-main-ms-ps-md.sql.temp ./pxc-main-ms-ps-md.sql
rm -f pxc-main-ms-ps-md.sql.tar.xz
tar -Jhcf pxc-main-ms-ps-md.sql.tar.xz pxc-main-ms-ps-md.sql
if [ -r pxc-main-ms-ps-md.sql.tar.xz ]; then
  # And not deleting pxc-main-ms-ps-md.sql for safety. pquery framework will untar .tar.xz in any case at the start of a pquery-run 
  rm -f pxc-main-ms-ps-md.sql.old
fi
