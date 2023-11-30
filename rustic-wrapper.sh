#!/bin/bash
#scriptname=$(echo "${0##*/}" | sed "s/.sh//g")

#MODIFY HERE
demo="false"

#NO LONGER NEEDED/USED as the list allows multiple mysql entries with a seperator
#specify your default db creds here if the site is not laravel or wordpress and it's a local database
#or
#Can also be used for remote databases
#or
#Use the "-m db_file.txt" command and specify your db credentials in that file
#database_list=(
#  "hostlocal,database2,user2,password2"
#  "hostremote,database3,user3,password3"
#)
backup_base="/home/backup/"
tmp_mount_point="/mnt/remote/"
ftp_parallel_downloads=10
ftp_pget=10
#log_file="/var/log/rustic-wrapper_log.txt"
#time in hours
job_max_time=6

#used in csv file for passwords with commas
comma_placeholder="__comma__"
#used in csv file to separate multiple db credentials
db_seperator="||"
#END MODIFY HERE

job_max_secs=$((job_max_time * 60 * 60))
#sudo touch $log_file

# Check if a command argument is provided
if [ $# -lt 1 ]; then
  echo -e "Usage: $0 [backup | delete | restore | snapshots | merge | info | prune]\n
  [additional flags...]
  [global]
  -r repo					e.g. -r /home/backup | -r \"rclone:WASABI\"
  -b bucket	required for rclone		e.g. -b backup_bucket
  -x password     default is blank				e.g. -x \"some_password\"
  
  [backup]
  -e:optional files_or_folders_to_exclude		e.g. -e \"wp-content/cache wp-content/litespeed wp-content/backup/ *.zip\"
  -k:optional number of days to keep			e.g.	-k 90
  -l:optional list_of_objects_to_backup			e.g. -l \"/home/backup_list.csv\"
  -m:optional list_of_db_to_backup			e.g. -m /home/db_list.csv
  -p path to backup					e.g. -p \"/home/back/me/up\"
  -c:optional instant delete when pruning
  -n:optional backup files newer than last snapshot time
  
  [snapshots]
  -i:optional snapshot to view			e.g.	-i jsd5jsdj
  
  
  [merge]
  -i list_of_snapshot_ids_or_id			e.g.	-i \"abcdefg hijk 156fsgsd\" | -i jsd5jsdj
  -c:optional used with merge to remove ids that were merged		e.g. merge -i \"abcdefg hijklm\" -c
  
  [restore]
  -p path to restore					e.g. -p \"/home/back/me/up\"
  -i snapshot to restore			e.g.	-i \"abcdefg hijk 156fsgsd\" | -i jsd5jsdj
  -d:optional destination_to_restore			e.g. /home/restorepoint/
  
  [delete]
  -i list_of_snapshot_ids_or_id			e.g.	-i \"abcdefg hijk 156fsgsd\" | -i jsd5jsdj
  -c:optional instant delete when pruning
  
  [info]
  
  [prune]
  -c:optional instant delete when pruning
  
  "
  exit 1
fi

# Read the command argument
primary_command="$1"

#START Helper functions

install_jq() {
	installed=$(sudo yum list installed|grep jq.x86_64)
	if [ "$installed" == "" ]; then
		sudo yum install -y jq 2>>/dev/null
		echo -e "jq Installed"
	fi
}

install_lftp() {
	installed=$(sudo yum list installed|grep lftp.x86_64)
	if [ "$installed" == "" ]; then
		sudo yum install -y lftp.x86_64 2>>/dev/null
		echo -e "lftp Installed"
	fi
}

install_wget() {
	installed=$(sudo yum list installed|grep wget.x86_64)
	if [ "$installed" == "" ]; then
		sudo yum install -y wget 2>>/dev/null
		echo -e "wget Installed"
	fi
}

install_at() {
	installed=$(sudo yum list installed|grep at.x86_64)
	if [ "$installed" == "" ]; then
		sudo yum install -y at 2>>/dev/null
		echo -e "at Installed"
	fi
}

install_rclone() {
	installed=$(sudo yum list installed|grep rclone.x86_64)
	if [ "$installed" == "" ]; then
		sudo yum install -y rclone 2>>/dev/null
		echo -e "rclone Installed"
	fi
}

re_comma() {
	original_string=$(echo "$1" | sed "s/$comma_placeholder/,/g")
	echo "$original_string"
}

is_base64_encoded() {
    local input_string="$1"
    local decoded_string

    decoded_string=$(echo "$input_string" | base64 -d 2>/dev/null | base64 2>/dev/null)

    if [ "$input_string" = "$decoded_string" ]; then
        return 0  # Success
    else
        return 1  # Failure
    fi
}

trim() {
	echo $(echo "$1" | awk '{$1=$1};1')
	#echo $(echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
}

decode_base64() {
    local input=$1
    local decoded

    # Check if the decoding was successful
    if is_base64_encoded "$input"; then
		# Try decoding the input
		decoded=$(echo "$input" | base64 -d 2>/dev/null)
        echo "$decoded"
    else
        # If decoding failed, return the original string
        echo "$input"
    fi
}

if [ ! -f "/usr/bin/rustic" ]; then
	install_wget
	#Install rustic
	wget https://github.com/rustic-rs/rustic/releases/download/v0.5.4/rustic-v0.5.4-x86_64-unknown-linux-musl.tar.gz 2>>/dev/null
	tar -xvzf rustic-v0.5.4-x86_64-unknown-linux-musl.tar.gz 2>>/dev/null
	mv rustic /usr/bin/rustic 2>>/dev/null
	sudo rm -f rustic-v0.5.4-x86_64-unknown-linux-musl.tar.gz 2>>/dev/null
	echo -e "Rustic Installed"
fi

string_in_array() {
  local target="$1"  # The string to search for
  shift             # Shift to the remaining arguments, which are the array elements

  # Iterate through the array elements
  for element in "$@"; do
    if [ "$element" = "$target" ]; then
      return 0  # Return success (0) if the target string is found
    fi
  done

  return 1  # Return failure (1) if the target string is not found
}

# Function to check if a string is valid JSON
is_json() {
  if jq -e . <<< "$1" &> $log_file; then
    return 0  # Return success (0) if it's valid JSON
  else
    return 1  # Return failure (1) if it's not valid JSON
  fi
}

# Function to strip trailing slashes
strip_trailing_slashes() {
  local input="$1"
  # Use parameter expansion to remove trailing slashes
  echo "${input%/}"
}

# Function to strip slashes at the beginning
strip_leading_slashes() {
  local input="$1"
  # Use parameter expansion to remove leading slashes
  echo "${input#/}"
}

# Function to check if a string is an integer
is_integer() {
  [[ $1 =~ ^[0-9]+$ ]]
}

resolve_ip() {
    local input=$1

    # Check if the input is a valid IP address
    if [[ $input =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$input"
		return
    else
        # Resolve the domain to an IP address
        resolved_ip=$(dig +short "$input")
		if [ "$resolved_ip" == "" ];then
			echo "$input"
		else
			echo "$resolved_ip"
		fi
		return
    fi
}

allow() {
	install_at
	ip=$(resolve_ip "$1")
	
	if [[ -v $2 ]] && is_integer "$2"; then
		local job_max_time=$(expr "$2" + 0)
		local job_max_secs=$((job_max_time * 60 * 60))
	fi
	
	if [ $(command -v csf) != "" ];then
		sudo csf --temprm $ip >/dev/null 2>&1
		sudo csf --tempallow $ip $job_max_secs -d out >/dev/null 2>&1
	elif [ $(command -v firewalld) != "" ];then
		sudo firewall-cmd --remove-rich-rule='rule family="ipv4" source address="$ip" accept' --permanent >/dev/null 2>&1
		sudo firewall-cmd --add-rich-rule='rule family="ipv4" source address="$ip" accept' --permanent >/dev/null 2>&1
		sudo firewall-cmd --reload >/dev/null 2>&1
		echo "sudo firewall-cmd --remove-rich-rule='rule family=\"ipv4\" source address=\"$ip\" accept' --permanent >/dev/null 2>&1" | at now + $job_max_time hour > /dev/null 2>&1
		echo "sudo firewall-cmd --reload >/dev/null 2>&1" | at now + $job_max_time hour > /dev/null 2>&1
	elif [ $(command -v iptables) != "" ];then
		sudo iptables -D OUTPUT -d $ip -j ACCEPT >/dev/null 2>&1
		sudo iptables -A OUTPUT -d $ip -j ACCEPT >/dev/null 2>&1
		echo "sudo iptables -D OUTPUT -d $ip -j ACCEPT >/dev/null 2>&1" | at now + $job_max_time hour > /dev/null 2>&1
	fi
}

disallow() {	
	ip=$(resolve_ip "$1")
	remove_at_job "$1"
	if [ $(command -v csf) != "" ];then
		sudo csf --temprm $ip >/dev/null 2>&1
	elif [ $(command -v firewalld) != "" ];then
		sudo firewall-cmd --remove-rich-rule='rule family="ipv4" source address="$ip" accept' --permanent >/dev/null 2>&1
		sudo firewall-cmd --reload >/dev/null 2>&1
	elif [ $(command -v iptables) != "" ];then
		sudo iptables -D OUTPUT -d $ip -j ACCEPT >/dev/null 2>&1
	fi
}

gen_tmp_file() {
	temp_name=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 18)
	echo "/tmp/$temp_name"
}

secure_dump() {
	#host user pass db output
	# Create a MySQL configuration file
	original_pass=$(re_comma "$3")
	mysql_tmp_config=$(gen_tmp_file)
	echo "[client]" > $mysql_tmp_config
	echo "host=$1" >> $mysql_tmp_config
	echo "user=$2" >> $mysql_tmp_config
	echo "password=$original_pass" >> $mysql_tmp_config
	sudo chmod 600 $mysql_tmp_config
	$(echo "sleep 5 ; sudo rm -f $mysql_tmp_config >/dev/null 2>&1" | at now > /dev/null 2>&1)
	mysqldump --defaults-file="$mysql_tmp_config" --single-transaction --quick --lock-tables=false --no-tablespaces $4 > "$5"
}

get_latest_snapshot_time() {
	#Get snapshot data
	result=$(sudo rustic -r $1 snapshots --json --password "$2" 2>>/dev/null)
	if [ "$result" == "" ]; then
		echo ""
		return
	fi
	
	# Path to compare
	path="$3"

	# Initialize variables
	latest_time=""
	latest_id=""

	# Iterate over each object in the array
	while read -r snapshot_data; do
		# Extract time and paths
		time=$(jq -r '.time' <<< "$snapshot_data")
		id=$(jq -r '.id' <<< "$snapshot_data")
		paths=$(jq -r '.paths' <<< "$snapshot_data")

		# Check if the paths match
		if [[ "$paths" == *"$path"* ]]; then
			# Check if time is more recent
			if [[ "$time" > "$latest_time" ]]; then
				latest_time="$time"
				latest_id="$id"
			fi
		fi
	done <<< "$(jq -c '.[0][1][]' <<< "$result")"

	echo "$latest_time"
}

get_at_time() {
	echo $(date -d "@$1" "+%Y-%m-%d %H:%M")
}

remove_at_job() {
	# Define the string to match
	target_string="$1"

	# Get a list of all at jobs
	job_list=$(atq)

	# Loop through each line in the job list
	echo "$job_list" | while read -r job_line; do
		# Check if the target string is present in the job line
		if [[ $job_line == *"$target_string"* ]]; then
			# Extract the job ID
			job_id=$(echo "$job_line" | awk '{print $1}')
			# Remove the job
			atrm "$job_id"
			echo "Job $job_id containing '$target_string' removed."
		fi
	done
}

extract_db_credentials() {
  # Search for .env and wp-config.php files in the current directory and its subdirectories
  
	find $1 -type f -name ".env" -o -name "wp-config.php" | while read -r file; do
		# Check if the file exists and is not empty
		if [ ! -s "$file" ]; then
		  continue
		fi

		# Determine the file type based on the extension
		file_type=""
		if [[ "$file" == *.env ]]; then
		  file_type="env"
		elif [[ "$file" == *wp-config.php ]]; then
		  file_type="wp-config"
		fi

		# Extract database credentials based on file type
		case "$file_type" in
		  "env")
			db_host=$(grep -E -o '^DB_HOST="?([^"]+)"?' "$file" | sed 's/DB_HOST=//;s/"//g')
			db_name=$(grep -E -o '^DB_DATABASE="?([^"]+)"?' "$file" | sed 's/DB_DATABASE=//;s/"//g')
			db_user=$(grep -E -o '^DB_USERNAME="?([^"]+)"?' "$file" | sed 's/DB_USERNAME=//;s/"//g')
			db_pass=$(grep -E -o '^DB_PASSWORD="?([^"]+)"?' "$file" | sed 's/DB_PASSWORD=//;s/"//g')
			;;
		  "wp-config")
			db_host=$(grep -E -o "define\(\s?'DB_HOST'\s?,\s?'([^']+)" "$file" | sed -E "s/define\\(\s?'DB_HOST',\s?'//")
			db_name=$(grep -E -o "define\(\s?'DB_NAME'\s?,\s?'([^']+)" "$file" | sed -E "s/define\\(\s?'DB_NAME',\s?'//")
			db_user=$(grep -E -o "define\(\s?'DB_USER'\s?,\s?'([^']+)" "$file" | sed -E "s/define\\(\s?'DB_USER',\s?'//")
			db_pass=$(grep -E -o "define\(\s?'DB_PASSWORD'\s?,\s?'([^']+)" "$file" | sed -E "s/define\\(\s?'DB_PASSWORD',\s?'//")
			;;
		  *)
			continue
			;;
		esac

		if [ "$db_host" == "" ]; then
			continue
		fi
	
		# Print the collected databases variable
		echo "$db_host,$db_name,$db_user,$db_pass"
	done
}

#END Helper functions
#---------------------------------------------------------------------------------------------------------

backup() {
	local path="$path"
	all_temp_paths=""
	
	get_all_dbs() {
	
		local repo=$1
		local path=""
		local db_backup_path=$3
	
		sudo rustic init -r $repo --password "$password"
		
		#Don't scan remote paths for databases as this will be very time consuming and the host will most likely be localhost
		#We only scan for local and not for rclone mounts or ftp locations
		if [[ -v $4 ]]; then
			return
		fi
		local databases=($(extract_db_credentials "$2"))

		sudo mkdir -p $db_backup_path 2>>/dev/null
		#sudo rm -rf $db_backup_path* >/dev/null 2>&1
		
		# Iterate through the list and run mysqldump for each set
		if [ "$databases" != "" ]; then
			for set in "${databases[@]}"; do
				IFS=',' read -r host db db_user db_pass <<< "$set"
				output_file="$db_backup_path${db}.sql"
				
				#don't export if the file was already exported
				#This protects agains multiple sites using the same database
				if [ ! -f "$output_file" ]; then
  
					if [ "$demo" == "true" ]; then
						echo -e "\nmysqldump --no-tablespaces -h$host -u$db_user -pNOT_REAL_PASSWORD $db > \"$output_file\""
					else
						secure_dump "$host" "$db_user" "$db_pass" "$db" "$output_file"
					fi
					
					if [ -f "$output_file" ]; then
						if [ -s "$output_file" ]; then
							path+=" $output_file"
						else
							sudo rm -f $output_file
						fi
					fi
				fi
			done
		fi
		
		
		# Iterate through the preset list and run mysqldump for each set
		#db_count=$(echo -n "$database_list" | wc -l)
		#if [ $db_count -gt 0 ]; then
		#	for set in "${database_list[@]}"; do
		#		IFS=',' read -r host db db_user db_pass <<< "$set"
		#		output_file="$db_backup_path${db}.sql"
		#		
		#		#don't export if the file was already exported
		#		#This protects agains multiple sites using the same database
		#		if [ ! -f "$output_file" ]; then
		#
		#			if [ "$demo" == "true" ]; then
		#				echo -e "\nmysqldump --no-tablespaces -h$host -u$db_user -pNOT_REAL_PASSWORD $db > \"$output_file\""
		#			else
		#				secure_dump "$host" "$db_user" "$db_pass" "$db" "$output_file"
		#			fi
		#			
		#			if [ -f "$output_file" ]; then
		#				if [ -s "$output_file" ]; then
		#					path+=" $output_file"
		#				else
		#					sudo rm -f $output_file
		#				fi
		#			fi
		#		fi
		#	done
		#fi
		if [ "$demo" != "true" ]; then
			echo $(trim "$path")
		fi
	}
	
	# Add your backup logic here
		
	# Iterate through the list and run mysqldump for each set
	if [ "$flag_db_list" != "" ] && [ -f "$flag_db_list" ]; then
			
		echo -e "Backing up from list: $flag_db_list"
		
		while IFS= read -r -d $'\n' line || [[ -n $line ]]; do
		
			#skip blank lines
			if [ "$line" == "" ]; then
				continue
			fi
			
			# Process the line when it ends with a line break and Remove optional quotes from the values
			line="${line%,}"  # Remove the trailing delimiter (",")
			IFS=, read -ra fields <<< "$line"
			bucket="${fields[0]//\"/}"
			host="${fields[1]//\"/}"
			db="${fields[2]//\"/}"
			db_user="${fields[3]//\"/}"
			db_pass="${fields[4]//\"/}"
			
			# Trim leading and trailing whitespace from the fields
			bucket=$(trim "$bucket")
			host=$(trim "$host")
			db=$(trim "$db")
			db_user=$(trim "$db_user")
			db_pass=$(trim "$db_pass")
			
			if [ "$host" == "" ] || [[ $host == "host" ]]; then
				continue
			fi
			
			base="$backup_base"
			if [ "$bucket" == "" ];then
				base=$(strip_trailing_slashes "$base")
			fi
			temp_db_path="$base$bucket/dbs/"
			all_temp_paths+=" $temp_db_path"
			sudo mkdir -p $temp_db_path 2>>/dev/null
			output_file="$temp_db_path${db}.sql"
			
			#don't export if the file was already exported
			#This protects agains multiple sites using the same database
			if [ ! -f "$output_file" ]; then
			
				ms_ip=$(resolve_ip "$host")
				allow "$ms_ip" 3
				if [ "$demo" == "true" ]; then
					echo -e "\nmysqldump --no-tablespaces -h$host -u$db_user -pNOT_REAL_PASSWORD $db > \"$output_file\""
				else
					secure_dump "$host" "$db_user" "$db_pass" "$db" "$output_file"
				fi
				
				if [ -f "$output_file" ]; then
					if [ -s "$output_file" ]; then
						path+=" $output_file"
					else
						sudo rm -f $output_file
					fi
				fi
				disallow "$ms_ip"
			fi
		done < "$flag_db_list"
	fi

	#If there is no list
	if [ "" == "$list" ]; then
		if [ "$path" == "" ] || [ ! -d "$path" ]; then
			echo -e "Backup directory doesn't exist"
			echo -e "This might be an error."
			#Exit removed since users may only want to backup databases
			#exit
		fi
		
		exclude=""
		if [ "" != "$flag_exclude" ]; then
			IFS=' ' read -ra flag_excludes <<< "$flag_exclude"
			for item in "${flag_excludes[@]}"; do
				item=$(strip_leading_slashes "$item")
				if [[ "$item" == *[*?]* ]]; then
					exclude="$exclude --glob '!${path}/${item}'"
				else
					exclude="$exclude --exclude-if-present '${path}/${item}'"
				fi
			done
		fi
			
		base="$backup_base"
		if [ "$bucket" == "" ];then
			base=$(strip_trailing_slashes "$base")
		fi
		temp_db_path="$base$bucket/dbs/"
		sudo mkdir -p $temp_db_path 2>>/dev/null
		#add the files exported using the -m list
		echo -e "Searching for databases to backup..."
  
		if [ "$demo" == "true" ]; then
			echo -e "find $path -type f -name \".env\" -o -name \"wp-config.php\""
			echo -e "$path $(get_all_dbs "$repo" "$path" "$temp_db_path")"
			echo -e "sudo rustic -r $repo backup $path --password \"NOT_REAL_PASSWORD\" $exclude"
		else
			path+=$(get_all_dbs "$repo" "$path" "$temp_db_path")
			if [ "$path" == "" ]; then
				echo -e "Nothing to backup!"
			fi
			eval "sudo rustic -r $repo backup $path --password \"$password\" $exclude"
			if [ "$retention" != "" ]; then
				instant=""
				if [[ -v flag_clean ]]; then
					instant="--instant-delete"
				fi
				eval "sudo rustic -r $repo forget --keep-daily $retention --prune $instant --password \"$password\""
			fi
		fi
		
		#cleanup
		sudo rm -rf $temp_db_path
	else
		echo -e "A list is provided, this overrides the path variable"
		echo -e ""
		# Check if the file exists
		if [ ! -f "$list" ]; then
			echo "File does not exist: $list"
			exit 1
		fi
		
		# Read and process each line in the file
		while IFS= read -r -d $'\n' line || [[ -n $line ]]; do
		
			#skip blank lines
			if [ "$line" == "" ]; then
				continue
			fi
			
			# Process the line when it ends with a line break and Remove optional quotes from the values
			line="${line%,}"  # Remove the trailing delimiter (",")
			IFS=, read -ra fields <<< "$line"
			
			local repo=$(trim "${fields[0]//\"/}")
			local bucket=$(trim "${fields[1]//\"/}")
			local retention=$(trim "${fields[2]//\"/}")
			local password=$(trim "${fields[3]//\"/}")
			local path=$(trim "${fields[4]//\"/}")
			local excludes=$(trim "${fields[5]//\"/}")
			local db=$(trim "${fields[6]//\"/}")
			local rmount=$(trim "${fields[7]//\"/}")
			local ftp=$(trim "${fields[8]//\"/}")
			local job_timeout=$(trim "${fields[9]//\"/}")
			local ftp_continue=$(trim "${fields[10]//\"/}")
			
			if [ "$repo" == "" ] || [[ $repo == "repository" ]]; then
				continue
			fi
			
			#echo -e "repo: $repo"
			#echo -e "bucket: $bucket"
			#echo -e "retention: $retention"
			#echo -e "password: $password"
			#echo -e "path: $path"
			#echo -e "excludes: $excludes"
			#echo -e "db: $db"
			#echo -e "rmount: $rmount"
			#echo -e "ftp: $ftp"
			#echo -e "\n"
			#continue
			
			path=$(strip_trailing_slashes "$path")
			files_path="$path"
			password=$(re_comma "$password")
			
			base="$backup_base"
			if [ "$bucket" == "" ];then
				base=$(strip_trailing_slashes "$base")
			fi
			temp_db_path="$base$bucket/dbs/"
			if [ "$bucket" != "" ]; then
				repo="$repo:$bucket"
			fi
			
			#--------------------------------------------------FTP--------------------------------------------------
			if [ "" != "$ftp" ]; then
				remote="true"
				#get ftp details if listed
				#"host user pass port"
				install_lftp
				ftp_fields=()

				# Use the read command to split the input string
				while IFS= read -r -d ' ' ftp_field; do
					ftp_fields+=("$ftp_field")
				done <<< "$ftp "
				
				path=$(strip_leading_slashes "$path")
				ftp_ip=$(resolve_ip "${ftp_fields[0]}")
				allow "$ftp_ip" "$job_timeout"
				
				mount_point=""
				if [ "$bucket" != "" ]; then
					mount_point="$bucket/"
				else
					mount_point="${ftp_fields[1]}/"
				fi
		
				exclude=""
				if [ "" != "$excludes" ]; then
					IFS=' ' read -ra flag_excludes <<< "$excludes"
					for item in "${flag_excludes[@]}"; do
						item=$(strip_leading_slashes "$item")
						if [[ "$item" == *[*?]* ]]; then
							exclude="$exclude --exclude-glob '${item}'"
						else
							exclude="$exclude --exclude ${item}"
						fi
					done
				fi
				remote_path="$path"
				path="${backup_base}${mount_point}files"
				files_path="$path"
				all_temp_paths+=" $path"
				sudo mkdir -p $path
				
				last_time=""
				if [ "$ftp_continue" != "" ] || [ "$ftp_continue" != 0 ]; then
					last_time=$(get_latest_snapshot_time "$repo" "$password" "$path")
					if [ "$last_time" != "" ];then
						at_time=$(get_at_time $(date -d "$last_time" "+%s"))
						last_time="--newer-than=\"$at_time\""
					fi
				fi
				
				echo -e "Downloading FTP files...${ftp_fields[1]}"
				if [ "$demo" == "true" ]; then
					echo -e "sudo lftp -e \"set ssl:verify-certificate no; cd /$remote_path; mirror -c --only-missing $last_time $exclude --skip-noaccess --parallel=$ftp_parallel_downloads --use-pget-n=$ftp_pget ./ $path; quit\" --user \"${ftp_fields[1]}\" --env-password -p ${ftp_fields[3]} ftp://$ip"
				else
					original_pass=$(re_comma "${ftp_fields[2]}")
					script_file=$(gen_tmp_file)
					echo "set ssl:verify-certificate no" > "$script_file"
					echo "open -p ${ftp_fields[3]} -u\"${ftp_fields[1]},$original_pass\" ftp://$ip" >> "$script_file"
					echo "cd /$remote_path" >> "$script_file"
					echo "mirror -c --only-missing $last_time $exclude --skip-noaccess --parallel=$ftp_parallel_downloads --use-pget-n=$ftp_pget ./ $path; quit" >> "$script_file"
					
					echo "sudo pkill -f $script_file >/dev/null 2>&1" | at now + $job_max_time hours > /dev/null 2>&1
					$(echo "sleep 5 ; sudo rm -f $script_file >/dev/null 2>&1" | at now > /dev/null 2>&1)
					sudo lftp -f "$script_file"
					#export LFTP_PASSWORD="$original_pass"
					#sudo lftp -e "set ssl:verify-certificate no; cd /$remote_path; mirror -c --only-missing $last_time $exclude --skip-noaccess --parallel=$ftp_parallel_downloads --use-pget-n=$ftp_pget ./ $path; quit" --user "${ftp_fields[1]}" --env-password -p ${ftp_fields[3]} ftp://$ip
				fi
				echo -e "Downloading FTP files COMPLETED!!\n"
			
			#--------------------------------------------------RCLONE--------------------------------------------------
			#rclone mount if there
			elif [ "$rmount" != "" ]; then
				remote="true"
				install_rclone
				
				mount_point=""
				if [ "$bucket" != "" ]; then
					mount_point="$bucket/"
				else
					mount_point="$rmount/"
				fi
				sudo mkdir -p ${tmp_mount_point}${mount_point} 2>>/dev/null
				umount -f ${tmp_mount_point}${mount_point} >/dev/null 2>&1
				echo -e "Mounting rclone remote path: $path"
				rmount_ip=$(rclone config show $rmount|grep host)
				rmount_ip=$(echo "$rmount_ip" | sed 's/\s*host\s*=\s*//')
				allow "$rmount_ip" "$job_timeout"
				sleep 2
				
				#echo -e "rclone mount $rmount:$path ${tmp_mount_point}${mount_point} &"
				rclone mount $rmount:$path ${tmp_mount_point}${mount_point} &
				
				sleep 5
				echo -e "\nMounted remote path\n"
				
				path="${backup_base}${mount_point}files"
				files_path="$path"
				all_temp_paths+=" $path"
				sudo mkdir -p $path
		
				exclude=""
				if [ "" != "$excludes" ]; then
					IFS=' ' read -ra flag_excludes <<< "$excludes"
					for item in "${flag_excludes[@]}"; do
						item=$(strip_leading_slashes "$item")
						exclude="$exclude --exclude=${item}"
					done
				fi
				
				echo -e "rclone is very slow, consider using ftp instead"
				sleep 3
				
				echo -e "Copying mounted files"
				if [ "$demo" == "true" ]; then
					echo -e "rsync -a $exclude ${tmp_mount_point}${mount_point} $path"
				else
					echo "sudo pkill -f ${tmp_mount_point}${mount_point} >/dev/null 2>&1" | at now + $job_max_time hours > /dev/null 2>&1
					rsync -a $exclude ${tmp_mount_point}${mount_point} $path
				fi
				echo -e "Copying mounted files COMPLETED!!\n"
			fi
			
			#--------------------------------------------------BACKUP EXCLUDES--------------------------------------------------
			
			sudo mkdir -p $temp_db_path 2>>/dev/null
			exclude=""
			if [ "" != "$excludes" ]; then
				IFS=' ' read -ra flag_excludes <<< "$excludes"
				for item in "${flag_excludes[@]}"; do
					item=$(strip_leading_slashes "$item")
					if [[ "$item" == *[*?]* ]]; then
						exclude="$exclude --glob '!${path}/${item}'"
					else
						exclude="$exclude --exclude-if-present '${path}/${item}'"
					fi
				done
			fi
			exclude=$(trim "$exclude")
			
			#--------------------------------------------------DB--------------------------------------------------
			#get main db if listed
			#host db user pass
			
			#Get all the dbs already exported for that backup path
			if [ -d "$temp_db_path" ]; then
				# Use find to list all files in the directory
				db_files=$(find "$temp_db_path" -type f -name '*.sql')

				# Loop through the files and concatenate them into a space-separated string
				for db_file in $db_files; do
					path+=" $db_file"
				done
			fi
			
			if [ "" != "$db" ]; then
			
				# Set the IFS to "||" to use it as a delimiter
				IFS="$db_seperator"
				
				# Split the string into an array
				read -ra mysql_parts <<< "$db"
				
				for db_details in "${mysql_parts[@]}"; do
					if [ "$db_details" == "" ]; then
						continue
					fi
					db_fields=()

					# Use the read command to split the input string
					# 0   1    2      3
					#host db user password
					while IFS= read -r -d ' ' db_field; do
						db_fields+=($(trim "$db_field"))
					done <<< "$db_details "
					
					output_file="$temp_db_path${db_fields[1]}.sql"
					if [ ! -f "$output_file" ]; then
						echo -e "Dumping DB..."
						db_ip=$(resolve_ip "${db_fields[0]}")
						allow "$db_ip" "$job_timeout"
						if [ "$demo" == "true" ]; then
							echo -e "\nmysqldump --no-tablespaces -h$db_ip -u${db_fields[2]} -pNOT_REAL_PASSWORD ${db_fields[1]} > \"$output_file\""
						else
							secure_dump "$db_ip" "${db_fields[2]}" "${db_fields[3]}" "${db_fields[1]}" "$output_file"
						fi
						
						if [ -f "$output_file" ]; then
							if [ -s "$output_file" ]; then
								path+=" $output_file"
							else
								sudo rm -f $output_file
							fi
						fi
						echo -e "Dumping DB COMPLETED!!\n"
					fi
				done
			fi
			
			#--------------------------------------------------Search For DBs--------------------------------------------------
			echo -e "Searching for databases to backup..."
  
			if [ "$demo" == "true" ]; then
				echo -e "find $path -type f -name \".env\" -o -name \"wp-config.php\" "
				echo -e "$path $(get_all_dbs "$repo" "$files_path" "$temp_db_path" "$remote")"
				echo -e "Searching for databases to backup COMPLETED!!"
				echo -e "sudo rustic -r $repo backup $path --password \"NOT_REAL_PASSWORD\" $exclude"
			else
				path+=$(get_all_dbs "$repo" "$files_path" "$temp_db_path" "$remote")
				echo -e "Searching for databases to backup COMPLETED!!\n"
				
				if [ $(trim "$path") == "" ]; then
					echo -e "Nothing to backup!"
					continue
				fi
				#add the files exported using the -m list
				eval "sudo rustic -r $repo backup $path $exclude --password \"$password\""
				if [ "$retention" != "" ]; then
					instant=""
					if [[ -v flag_clean ]]; then
						instant="--instant-delete"
					fi
					eval "sudo rustic -r $repo forget --keep-daily $retention --prune $instant --password \"$password\""
				fi
			fi
			#--------------------------------------------------CLEANUP--------------------------------------------------
			
			#cleanup
			echo -e "\nCleaning up!!\n"
			#rclone unmount if mounted
			if [[ -v rmount_ip ]]; then
				echo -e "Unmounting drive\n"
				umount -f ${tmp_mount_point}${mount_point} >/dev/null 2>&1
				# Check if the directory is empty
				if [ -z "$(find "${tmp_mount_point}${mount_point}" -maxdepth 1 -type f)" ]; then
					sudo rm -rf ${tmp_mount_point}${mount_point}
				fi
				disallow "$rmount_ip"
			fi
			if [[ -v ftp_ip ]]; then
				disallow "$ftp_ip"
			fi
			if [[ -v db_ip ]]; then
				disallow "$db_ip"
			fi
			
			sudo rm -rf $temp_db_path >/dev/null 2>&1
			echo -e "\n----------------------------------------------------------\n\n"
		done < "$list"
		
		echo -e "Removing temporary files & directories\n"
		all_temp_paths=$(trim "$all_temp_paths")
		if [ "$all_temp_paths" != "" ];then
			all_temp_paths=($all_temp_paths)
			for tpath in "${all_temp_paths[@]}"; do
				sudo rm -rf $tpath >/dev/null 2>&1
			done
		fi
	fi
}

delete() {
	
	if [ "$ids" == "" ]; then
		#Since the array is empty, we need to ask for the snapshot ID
		echo -e "Snapshots listed below:"
		sudo rustic -r $repo snapshots --password "$password"
		
		echo -e "Enter snapshot id:"
		read snapshot_id
		
		echo "Performing delete..."
		# Add your delete logic here
  
		if [ "$demo" == "true" ]; then
			echo -e "sudo rustic -r $repo forget $snapshot_id --prune --password \"NOT_REAL_PASSWORD\""
		else
			sudo rustic -r $repo forget $snapshot_id --prune --password "$password"
		fi
	else
		local ids=($ids)
		for snapshot_id in "${ids[@]}"; do
			echo "Processing Snapshot ID: $snapshot_id"
			# Add your logic to process additional options here
		  
			echo "Performing delete..."
			# Add your delete logic here
  
			if [ "$demo" == "true" ]; then
				echo -e "sudo rustic -r $repo forget $snapshot_id --prune --password \"NOT_REAL_PASSWORD\""
			else
				sudo rustic -r $repo forget $snapshot_id --password "$password"
			fi
		done
  
		if [ "$demo" == "true" ]; then
			echo -e "sudo rustic -r $repo prune --password \"NOT_REAL_PASSWORD\""
		else
			sudo rustic -r $repo prune --password "$password"
		fi
	fi
}

restore() {
	
	if [ "$snapshot_id" == "" ]; then
		#No options present so we prompt
		echo -e "Snapshots listed below:"
		sudo rustic -r $repo snapshots --password "$password"
		
		echo -e "Enter snapshot id:"
		read snapshot_to_restore
		
		#Now we get snapshot data to see if it's valid
		result=$(sudo rustic -r $repo snapshots $snapshot_to_restore --json --password "$password" 2>>/dev/null)
		if [ "$result" == "" ] || [ "$result" == "[]" ]; then
			echo "Error: no suitable id found for $snapshot_to_restore"
			exit 1
		fi
		
		install_jq
		snapshot_data=$(jq -c '.[0][1][0]' <<< "$result")
		paths=$(jq -c '.paths' <<< "$snapshot_data")
			
		base="$backup_base"
		if [ "$bucket" == "" ];then
			base=$(strip_trailing_slashes "$base")
		fi
		restore_path="$base$bucket/restored/"
		sudo mkdir -p $restore_path
		
		while true; do
			echo -e "Restore to default location? y/n"
			echo -e "If no, it will be restored to a temporary location. $restore_path"
			read destination

			# Check the user's input
			if [ "$destination" = "y" ] || [ "$destination" = "Y" ]; then
				# Add your processing code here
				destination="$path"
				break  # Exit the loop if valid input is received
			elif [ "$destination" = "n" ] || [ "$destination" = "N" ]; then
				sudo mkdir -p $restore_path
				# Add any actions to take when the user chooses "no"
				destination="$restore_path"
				break  # Exit the loop if valid input is received
			else
				echo -e "Invalid input. Please enter 'y' for yes or 'n' for no."
			fi
		done
		
		while true; do
			echo -e "Restore all? y/n"
			read all

			# Check the user's input
			if [ "$all" = "y" ] || [ "$all" = "Y" ]; then
				echo "Processing... You chose to proceed."
				# Add your processing code here
				echo "Performing restore... to $destination"
				# Add your restore logic here
  
				if [ "$demo" == "true" ]; then
					echo -e "sudo rustic -r $repo restore $snapshot_to_restore $destination --password ''"
				else
					sudo rustic -r $repo restore $snapshot_to_restore $destination --password "$password"
				fi
				break  # Exit the loop if valid input is received
			elif [ "$all" = "n" ] || [ "$all" = "N" ]; then
				# Add any actions to take when the user chooses "no"		
				echo -e "Enter paths to restore separated by a space"
				read destinations
				
				while IFS= read -r -d ' ' path; do
  
					if [ "$demo" == "true" ]; then
						echo -e "sudo rustic -r $repo restore $snapshot_to_restore:$path $destination --password ''"
					else
						sudo rustic -r $repo restore $snapshot_to_restore:$path $destination/$path --password "$password"
					fi
				done <<< "$destinations "
				
				break  # Exit the loop if valid input is received
			else
				echo -e "Invalid input. Please enter 'y' for yes or 'n' for no."
			fi
		done
	else
		#Options were supplied to the script already so no need to prompt
		#Now we get snapshot data
		snapshot_to_restore="$snapshot_id"
		paths_to_restore="$path"
		final_path="$destination"
		
		#Now we get snapshot data to see if it's valid
		result=$(sudo rustic -r $repo snapshots $snapshot_to_restore --json --password "$password" 2>>/dev/null)
		if [ "$result" == "" ]; then
			echo "Error: no suitable id found for $snapshot_to_restore"
			exit 1
		fi
		snapshot_data=$(jq -c '.[0][1][0]' <<< "$result")
		paths=$(jq -c '.paths' <<< "$snapshot_data")
		
		if [ "$paths_to_restore" == "" ]; then
			#Restore all
  
			if [ "$demo" == "true" ]; then
				echo -e "sudo rustic -r $repo restore $snapshot_to_restore $destination --password \"NOT_REAL_PASSWORD\""
			else
				sudo rustic -r $repo restore $snapshot_to_restore $destination --password "$password"
			fi
		else
			while IFS= read -r -d ' ' path; do
  
				if [ "$demo" == "true" ]; then
					echo -e "sudo rustic -r $repo restore $snapshot_to_restore:$path $destination --password ''"
				else
					sudo rustic -r $repo restore $snapshot_to_restore:$path $destination/$path --password "$password"
				fi
			done <<< "$paths_to_restore "
		fi
	fi
	
	echo "Restored to $destination"
}

snapshots() {
	echo "Viewing snapshots..."
	# Add your snapshots logic here
	sudo rustic -r $repo snapshots $ids --password "$password"
}

merge() {
	echo "Merging snapshots..."
	# Add your merge logic here
	
	if [ "$ids" != "" ];then
  
		if [ "$demo" == "true" ]; then
			echo -e "sudo rustic -r $repo merge $ids --password \"NOT_REAL_PASSWORD\""
		else
			sudo rustic -r $repo merge $ids --password "$password"
			if [[ -v flag_clean ]]; then
				#delete the same ids that were merged and prune
				delete
			fi
			prune
		fi
	else
		#Now we get snapshot data to see if it's valid
		result=$(sudo rustic -r $repo snapshots --json --password "$password" 2>>/dev/null)
		if [ "$result" == "" ]; then
			echo "Error: no snapshots to merge"
			exit 1
		fi
		
		jq -c '.[]' <<< "$result" | while read -r snapshot_datas; do
			ids=$(echo "$snapshot_datas" | jq -r '.[1] | .[] | .id' | tr '\n' ' ')
			
			if [ $(echo "$ids" | tr -cd ' ' | wc -c) == 0 ]; then
				continue
			fi
  
			if [ "$demo" == "true" ]; then
				echo -e "sudo rustic -r $repo merge $ids --password \"NOT_REAL_PASSWORD\""
			else
				sudo rustic -r $repo merge $ids --password "$password"
			fi
			
			#remove previous ids
			if [[ -v flag_clean ]]; then
				#delete the same ids that were merged and prune
				delete
			fi
			prune
		done
	fi
}

info() {
	echo "Viewing snapshots..."
	# Add your snapshots logic here
	sudo rustic repoinfo -r $repo --password "$password"
}

prune() {
	echo "Viewing snapshots..."
	# Add your snapshots logic here
	instant=""
	if [[ -v flag_clean ]]; then
		instant="--instant-delete"
	fi
  
	if [ "$demo" == "true" ]; then
		echo -e "sudo rustic prune -r $repo $instant --password \"NOT_REAL_PASSWORD\""
	else
		sudo rustic prune -r $repo $instant --password "$password"
	fi
}


# Handle additional options if provided
shift   # Remove the processed primary command
additional_options=("$@")  # Store the remaining arguments

#TEST AREA


#exit 1
#END TEST AREA

echo -e "\n-----------------START $(date +"%a %d %b %Y - %I:%M%p")-----------------\n"

while getopts "b:cd:e:i:k:l:m:p:r:s:x:" flag
do
	case "${flag}" in
		b) flag_bucket=${OPTARG};;
		c) flag_clean=1;;
		d) flag_destination=${OPTARG};;
		e) flag_exclude=${OPTARG};;
		i) flag_ids=${OPTARG};;
		k) flag_retention=${OPTARG};;
		l) flag_list=${OPTARG};;
		m) flag_db_list=${OPTARG};;
		n) flag_newer=1;;
		p) flag_path=${OPTARG};;
		r) flag_repo=${OPTARG};;
		s) flag_snapshot=${OPTARG};;
		x) flag_password=${OPTARG};;
	esac
done

if [ -z "$flag_repo" ] && [ -z "$flag_list" ]; then
	echo -e "No Repository provided, please provide a repository by passing -r reponame"
	exit
else
	repo="$flag_repo"
fi

if [ -z "$flag_bucket" ]; then
	echo -e "No Bucket provided, Repo might be local"
	bucket=""
else
	bucket="$flag_bucket"
	repo="$repo:$bucket"
	install_rclone
fi

if [ -z "$flag_destination" ]; then
		
	if [ "$primary_command" == "restore" ] && [ "$bucket" == "" ];then
		backup_base=$(strip_trailing_slashes "$backup_base")
	fi
	destination="$backup_base$bucket/restored/"
else
	destination="$flag_destination"
fi

if [ -z "$flag_exclude" ]; then
	flag_exclude=""
fi

if [ -z "$flag_path" ]; then
	if [ "$primary_command" == "backup" ] && [ -z "$flag_list" ]; then
		echo -e "No backup path provided, please provide a repository by passing -p path"
		exit
	fi
	path=""
	echo -e "No path provided"
else
	path="$flag_path"
fi

if [ -z "$flag_ids" ]; then
	ids=""
	snapshot_id=""
else
	ids="$flag_ids"
	snapshot_id="$flag_ids"
fi

if [ -z "$flag_retention" ]; then
	retention=""
else
	if is_integer "$flag_retention"; then
		retention="$flag_retention"
	else
		retention=""
	fi
fi

#list of files to backup
if [ -z "$flag_list" ]; then
	list=""
else
	list="$flag_list"
fi

#list of db to backup
if [ -z "$flag_db_list" ]; then
	flag_db_list=""
fi

if [ -z "$flag_password" ]; then
	password=""
else
	password="$flag_password"
fi

# Process the command using a case statement
case "$primary_command" in
  "backup")
    backup
    ;;

  "delete")
    delete
    ;;

  "remove")
    delete
    ;;

  "restore")
    restore
    ;;

  "snapshots")
    snapshots
    ;;

  "merge")
    merge
    ;;

  "info")
    info
    ;;

  "prune")
    prune
    ;;

  *)
    echo "Invalid command: $command"
    echo "Usage: $0 [backup | delete | restore | snapshots]"
    exit 1
    ;;
esac
echo -e "\n-----------------END $(date +"%a %d %b %Y - %I:%M%p")-----------------\n"
