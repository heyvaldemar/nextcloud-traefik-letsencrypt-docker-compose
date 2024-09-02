# Nextcloud with Let's Encrypt Using Docker Compose

📙 The complete installation guide is available on my [website](https://www.heyvaldemar.com/install-nextcloud-using-docker-compose/).

❗ Change variables in the `.env` to meet your requirements.

💡 Note that the `.env` file should be in the same directory as `nextcloud-traefik-letsencrypt-docker-compose.yml`.

Create networks for your services before deploying the configuration using the commands:

`docker network create traefik-network`

`docker network create nextcloud-network`

Deploy Nextcloud using Docker Compose:

`docker compose -f nextcloud-traefik-letsencrypt-docker-compose.yml -p nextcloud up -d`

# Background Jobs Using Cron

To ensure your Nextcloud instance operates efficiently, it's important to use the "Cron" method to execute background jobs. A dedicated Docker container has already been set up in your environment to handle these tasks.

## Steps to Enable Cron:

1. **Log in to Nextcloud as an Administrator.**
2. Go to **Settings** (click on your user profile in the top right corner and select "Settings").
3. In the **Administration** section on the left sidebar, select **Basic settings**.
4. Scroll down to the **Background jobs** section.
5. Select the **"Cron (Recommended)"** option.

![nextcloud-cron](https://github.com/user-attachments/assets/1fdbf1af-a250-481d-b3b5-6a6cb98b6c51)

## Why Use Cron?

The "Cron" method ensures that background tasks, such as file indexing, notifications, and cleanup operations, run at regular intervals independently of user activity. This method is more reliable and efficient than AJAX or Webcron, particularly for larger or more active instances, as it does not depend on users accessing the site to trigger these tasks. With the dedicated container in your setup, this method keeps your Nextcloud instance responsive and in good health by running these jobs consistently.

# Backups

The `backups` container in the configuration is responsible for the following:

1. **Database Backup**: Creates compressed backups of the PostgreSQL database using pg_dump.
Customizable backup path, filename pattern, and schedule through variables like `POSTGRES_BACKUPS_PATH`, `POSTGRES_BACKUP_NAME`, and `BACKUP_INTERVAL`.

2. **Application Data Backup**: Compresses and stores backups of the application data on the same schedule. Controlled via variables such as `DATA_BACKUPS_PATH`, `DATA_BACKUP_NAME`, and `BACKUP_INTERVAL`.

3. **Backup Pruning**: Periodically removes backups exceeding a specified age to manage storage. Customizable pruning schedule and age threshold with `POSTGRES_BACKUP_PRUNE_DAYS` and `DATA_BACKUP_PRUNE_DAYS`.

By utilizing this container, consistent and automated backups of the essential components of your instance are ensured. Moreover, efficient management of backup storage and tailored backup routines can be achieved through easy and flexible configuration using environment variables.

# nextcloud-restore-database.sh Description

This script facilitates the restoration of a database backup:

1. **Identify Containers**: It first identifies the service and backups containers by name, finding the appropriate container IDs.

2. **List Backups**: Displays all available database backups located at the specified backup path.

3. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list to restore the database.

4. **Stop Service**: Temporarily stops the service to ensure data consistency during restoration.

5. **Restore Database**: Executes a sequence of commands to drop the current database, create a new one, and restore it from the selected compressed backup file.

6. **Start Service**: Restarts the service after the restoration is completed.

To make the `nextcloud-restore-database.shh` script executable, run the following command:

`chmod +x nextcloud-restore-database.sh`

Usage of this script ensures a controlled and guided process to restore the database from an existing backup.

# nextcloud-restore-application-data.sh Description

This script is designed to restore the application data:

1. **Identify Containers**: Similarly to the database restore script, it identifies the service and backups containers by name.

2. **List Application Data Backups**: Displays all available application data backups at the specified backup path.

3. **Select Backup**: Asks the user to copy and paste the desired backup name for application data restoration.

4. **Stop Service**: Stops the service to prevent any conflicts during the restore process.

5. **Restore Application Data**: Removes the current application data and then extracts the selected backup to the appropriate application data path.

6. **Start Service**: Restarts the service after the application data has been successfully restored.

To make the `nextcloud-restore-application-data.sh` script executable, run the following command:

`chmod +x nextcloud-restore-application-data.sh`

By utilizing this script, you can efficiently restore application data from an existing backup while ensuring proper coordination with the running service.

# Author

I’m Vladimir Mikhalev, the [Docker Captain](https://www.docker.com/captains/vladimir-mikhalev/), but my friends can call me Valdemar.

🌐 My [website](https://www.heyvaldemar.com/) with detailed IT guides\
🎬 Follow me on [YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1)\
🐦 Follow me on [Twitter](https://twitter.com/heyValdemar)\
🎨 Follow me on [Instagram](https://www.instagram.com/heyvaldemar/)\
🧵 Follow me on [Threads](https://www.threads.net/@heyvaldemar)\
🐘 Follow me on [Mastodon](https://mastodon.social/@heyvaldemar)\
🧊 Follow me on [Bluesky](https://bsky.app/profile/heyvaldemar.bsky.social)\
🎸 Follow me on [Facebook](https://www.facebook.com/heyValdemarFB/)\
🎥 Follow me on [TikTok](https://www.tiktok.com/@heyvaldemar)\
💻 Follow me on [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)\
🐈 Follow me on [GitHub](https://github.com/heyvaldemar)

# Communication

👾 Chat with IT pros on [Discord](https://discord.gg/AJQGCCBcqf)\
📧 Reach me at ask@sre.gg

# Give Thanks

💎 Support on [GitHub](https://github.com/sponsors/heyValdemar)\
🏆 Support on [Patreon](https://www.patreon.com/heyValdemar)\
🥤 Support on [BuyMeaCoffee](https://www.buymeacoffee.com/heyValdemar)\
🍪 Support on [Ko-fi](https://ko-fi.com/heyValdemar)\
💖 Support on [PayPal](https://www.paypal.com/paypalme/heyValdemarCOM)
