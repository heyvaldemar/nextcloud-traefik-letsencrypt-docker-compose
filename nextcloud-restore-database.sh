#!/bin/bash

NEXTCLOUD_CONTAINER=$(docker ps -aqf "name=nextcloud_nextcloud")
NEXTCLOUD_BACKUPS_CONTAINER=$(docker ps -aqf "name=nextcloud_backups")

echo "--> All available database backups:"

for entry in $(docker container exec -it $NEXTCLOUD_BACKUPS_CONTAINER sh -c "ls /srv/nextcloud-postgres/backups/")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore database and press [ENTER]
--> Example: nextcloud-postgres-backup-YYYY-MM-DD_hh-mm.gz"
echo -n "--> "

read SELECTED_DATABASE_BACKUP

echo "--> $SELECTED_DATABASE_BACKUP was selected"

echo "--> Stopping service..."
docker stop $NEXTCLOUD_CONTAINER

echo "--> Restoring database..."
docker exec -it $NEXTCLOUD_BACKUPS_CONTAINER sh -c 'PGPASSWORD="$(echo $POSTGRES_PASSWORD)" dropdb -h postgres -p 5432 nextclouddb -U nextclouddbuser \
&& PGPASSWORD="$(echo $POSTGRES_PASSWORD)" createdb -h postgres -p 5432 nextclouddb -U nextclouddbuser \
&& PGPASSWORD="$(echo $POSTGRES_PASSWORD)" gunzip -c /srv/nextcloud-postgres/backups/'$SELECTED_DATABASE_BACKUP' | PGPASSWORD=$(echo $POSTGRES_PASSWORD) psql -h postgres -p 5432 nextclouddb -U nextclouddbuser'
echo "--> Database recovery completed..."

echo "--> Starting service..."
docker start $NEXTCLOUD_CONTAINER
