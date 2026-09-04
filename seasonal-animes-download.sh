#!/bin/bash

# SCRIPT VARIABLES
SCRIPT_FOLDER=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
media_type=animes
source "$SCRIPT_FOLDER/config/.env"
source "$SCRIPT_FOLDER/functions.sh"

# check if files and folder exist
if [ ! -d "$SCRIPT_FOLDER/config/data" ]										#check if exist and create folder for json data
then
	mkdir "$SCRIPT_FOLDER/config/data"
fi
if [ ! -d "$SCRIPT_FOLDER/config/tmp" ]										#check if exist and create folder for json data
then
	mkdir "$SCRIPT_FOLDER/config/tmp"
fi
:> "$SCRIPT_FOLDER/config/data/seasonal.tsv"

#SCRIPT
printf "%s - Starting script\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s - Downloading the current season\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
# the only list here that is not about the plex library, so it is the one thing still asked of the API in bulk.
# anilist files december under the next year's winter and /seasons/now accounts for it, which a date computed here would not.
if ! animemap-api-get "$ANIMEMAP_API_URL/seasons/now?limit=100" "$SCRIPT_FOLDER/config/tmp/this-season.json"
then
	printf "%s - Error can't download the current season stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	exit 1
fi
season=$(jq '.entries[0].season // empty' -r "$SCRIPT_FOLDER/config/tmp/this-season.json")
year=$(jq '.entries[0].season_year // empty' -r "$SCRIPT_FOLDER/config/tmp/this-season.json")
if [[ -z $season ]] || [[ -z $year ]]
then
	printf "%s - Error the current season is empty stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	exit 1
fi
printf "%s - Current season : %s %s\n\n" "$(date +%H:%M:%S)" "$season" "$year" | tee -a "$LOG"
printf "%s - Creating seasonal list\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
jq --argjson limit "$DOWNLOAD_LIMIT" '[ .entries[] | select( .format == "TV" ) ]
	| sort_by( - ( .average_score // 0 ) ) | .[0:$limit] | .[].anilist_id' -r "$SCRIPT_FOLDER/config/tmp/this-season.json" > "$SCRIPT_FOLDER/config/tmp/seasonal-animemap.tsv"
printf "%s\t - Sorting seasonal list\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
while read -r anilist_id
do
	get-animemap-infos																	# the entry knows its own tvdb id, season and offset
	tvdb_id=$(jq '.tvdb_id // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	tvdb_season=$(jq '.tvdb_season // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	tvdb_epoffset=$(jq '.tvdb_epoffset // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	if [[ -z $tvdb_id ]]
	then
		printf "%s\t\t - Seasonal invalid TVDB ID for Anilist : %s\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
		continue
	fi
	if [[ "$tvdb_season" -eq 1 ]] && [[ "$tvdb_epoffset" -eq 0 ]]
	then
		printf "%s\n" "$tvdb_id" >> "$SCRIPT_FOLDER/config/data/seasonal.tsv"
		printf "%s\t\t - New seasonal anime adding to list : Anilist id : %s / tvdb id : %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$tvdb_id" | tee -a "$LOG"
	else
		printf "%s\t\t - Sequel seasonal anime not adding to list : Anilist id : %s / tvdb id : %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$tvdb_id" | tee -a "$LOG"
	fi
done < "$SCRIPT_FOLDER/config/tmp/seasonal-animemap.tsv"
printf "%s - Done\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"


tvdb_list=$(awk '{printf("%s, ",$0 )}' "$SCRIPT_FOLDER/config/data/seasonal.tsv" | sed 's/,\s*$//')
printf "%s - Wrinting seasonal collection\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s - Seasonal list : tvdb id added : %s\n" "$(date +%H:%M:%S)" "$tvdb_list"| tee -a "$LOG"
printf "collections:\n  seasonal animes download:\n    tvdb_show: %s\n    sync_mode: append\n    sonarr_add_missing: true\n    build_collection: false\n" "$tvdb_list" > "$DOWNLOAD_ANIMES_COLLECTION"
printf "%s - Done\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s - Run finished\n\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"