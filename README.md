# rustic-wrapper
A bash script for Rhel systems using [Rustic](https://github.com/rustic-rs/rustic) to automate backups.
- [x] Supports the backup of local, FTP and rclone locations
- [x] Supports remote MySQL backups
- [x] Automatically finds WordPress and Laravel Databases to backup within the path
- [x] Can be modified to pull details from a mysql database instead of a csv
- [x] Can be modified to automatically backup databases from other frameworks
- [x] Sample provided
- [ ] Does not support commas, please use a placeholder. default = \_\_comma__

### Make sure to secure your backup list
> chmod 700 /root/rustic-wrapper.sh\
> chmod 400 /root/file.csv

### Settings
Modify default settings in file to your liking\
demo mode - default: "false"\
logging - default: "true"\
parallell downloads for FTP - default: 10\
max job time - default: 6hrs\
rustic cache - default: "false"\
default level 1 directories to exclude in local backups: "vmail backup backups cyberpanel clamav virtfs cPanelInstall htroot docker"

### Requirements
**Atomatically installs**\
wget\
at\
rustic\
rclone\
lftp\
jq
_______________

**Usage:**\
./rustic-wrapper.sh [backup | local_backup | delete | restore | snapshots | merge | info | prune]

  [additional flags...]\
  **[global]**
  ```
  -r repo					                        e.g. -r /home/backup | -r "rclone:WASABI"
  -b bucket	required for rclone		                e.g. -b backup_bucket
  -x password     default is blank				e.g. -x "some_password"
  ```
  
  **[backup]**
  ```
  -e:optional files_or_folders_to_exclude, allows glob            e.g. -e "wp-content/cache wp-content/litespeed wp-content/backup/ *.zip"
  -k:optional number of days to keep			        e.g.	-k 90
  -l:optional list_of_objects_to_backup			        e.g. -l "/home/backup_list.csv"
  -m:optional list_of_db_to_backup			        e.g. -m /home/db_list.csv
  -p path to backup					        e.g. -p "/home/back/me/up"
  -c:optional instant delete when pruning
  -n:optional backup files newer than last snapshot time
  ```
  
  **[local_backup]**
  ```
  -r:optional repo/backup path
  -e:optional files_or_folders_to_exclude    e.g. -e \"wp-content/cache wp-content/litespeed wp-content/backup/ *.zip\"
  -k:optional number of days to keep      e.g.	-k 90
  -c:optional instant delete when pruning
  -p:optional level 1 directories to exclude, this replaces local_excluded_dirs
  ```
  
  **[snapshots]**
  ```
  -i:optional snapshot to view			                e.g.	-i jsd5jsdj
  ```
  
  
  **[merge]**
  ```
  -i list_of_snapshot_ids_or_id			                e.g.	-i "abcdefg hijk 156fsgsd" | -i jsd5jsdj
  -c:optional used with merge to remove ids that were merged      e.g. merge -i "abcdefg hijklm" -c
  ```
  
  **[restore]**
  ```
  -p path to restore                            e.g. -p "/home/back/me/up"
  -i snapshot to restore                        e.g.	-i "abcdefg hijk 156fsgsd" | -i jsd5jsdj
  -d:optional destination_to_restore            e.g. /home/restorepoint/
  ```
  
  **[delete]**
  ```
  -i list_of_snapshot_ids_or_id			        e.g.	-i "abcdefg hijk 156fsgsd" | -i jsd5jsdj
  -c:optional instant delete when pruning
  ```
  
  **[info]**
  
  **[prune]**
  ```
  -c:optional instant delete when pruning
  ```

_______________

## Example usage
Before running the script, update your settings within the file between the tags #MODIFY HERE and #END MODIFY HERE
> ./rustic-wrapper.sh backup -l /path/to/csv_file/file.csv

> ./rustic-wrapper.sh backup -r rclone:WASABI_DRIVE -b example.com -e "*.zip *.gz backup cache /home/example/public_html/cache" -k 120 -p /home/example/public_html/ -c -x "MyPassword"

Specify full paths to exclude that specific file or folder in excludes
e.g. if you want to exclude /home/test/cache but backup all other cache folders specify: -e "/home/test/cache backup *.zip"
e.g. if you want to exclude all cache directories specify: -e "cache backup *.zip"


**Cron**\
#Generally used to backup offsite locations using ftp or preconfigured rclone configs
> 0 0 * * * /root/rustic-wrapper.sh backup -l /path/to/csv_file/file.csv

#backup all directories in the /home/ directory to the default backup path
> 0 0 * * * /root/rustic-wrapper.sh local_backup

#backup all directories (except listed) in the /home/ directory to the default backup path
> 0 0 * * * /root/rustic-wrapper.sh local_backup -p "mysql test backup backups"

#backup all directories (except listed) in the /home/ directory to the repo path specified (can be used to backup to an NFS mounted path)
> 0 0 * * * /root/rustic-wrapper.sh local_backup -p "mysql test backup backups" -r /home/local-rustic-wrapper/
