#!/bin/bash

# # nextcloud-restore-application-data.sh Description
# This script is designed to restore the application data.
# 1. **Identify Containers**: Similarly to the database restore script, it identifies the service and backups containers by name.
# 2. **List Application Data Backups**: Displays all available application data backups at the specified backup path.
# 3. **Select Backup**: Asks the user to copy and paste the desired backup name for application data restoration.
# 4. **Stop Service**: Stops the service to prevent any conflicts during the restore process.
# 5. **Restore Application Data**: Removes the current application data and then extracts the selected backup to the appropriate application data path.
# 6. **Start Service**: Restarts the service after the application data has been successfully restored.
# To make the `nextcloud-restore-application-data.sh` script executable, run the following command:
# `chmod +x nextcloud-restore-application-data.sh`
# By utilizing this script, you can efficiently restore application data from an existing backup while ensuring proper coordination with the running service.

NEXTCLOUD_CONTAINER=$(docker ps -aqf "name=nextcloud-nextcloud")
NEXTCLOUD_BACKUPS_CONTAINER=$(docker ps -aqf "name=nextcloud-backups")
BACKUP_PATH="/srv/nextcloud-application-data/backups/"
RESTORE_PATH="/var/www/html/"
BACKUP_PREFIX="nextcloud-application-data"

echo "--> All available application data backups:"

for entry in $(docker container exec -it "$NEXTCLOUD_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore application data and press [ENTER]
--> Example: ${BACKUP_PREFIX}-backup-YYYY-MM-DD_hh-mm.tar.gz"
echo -n "--> "

read SELECTED_APPLICATION_BACKUP

echo "--> $SELECTED_APPLICATION_BACKUP was selected"

echo "--> Stopping service..."
docker stop "$NEXTCLOUD_CONTAINER"

echo "--> Restoring application data..."
docker exec -it "$NEXTCLOUD_BACKUPS_CONTAINER" sh -c "rm -rf ${RESTORE_PATH}* && tar -zxpf ${BACKUP_PATH}${SELECTED_APPLICATION_BACKUP} -C /"
echo "--> Application data recovery completed..."

echo "--> Starting service..."
docker start "$NEXTCLOUD_CONTAINER"
