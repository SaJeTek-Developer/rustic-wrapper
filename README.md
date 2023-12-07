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
demo mode - default: "false"\
logging - default: "true"\
parallell downloads for FTP - default: 10\
max job time - default: 6hrs

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
./rustic-wrapper.sh [backup | delete | restore | snapshots | merge | info | prune]

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


**Cron**\
0 0 * * * /root/rustic-wrapper.sh backup -l /path/to/csv_file/file.csv
