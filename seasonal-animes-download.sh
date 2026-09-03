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
download-animemap-data
printf "%s - checking current season\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
# anilist files december under the next year's winter, which is what the catalog already reflects, so read the season off the entries that are releasing now
season=$(jq -s '[ .[] | select( .status == "RELEASING" ) | select( .season != null and .season_year != null ) | "\(.season_year) \(.season)" ] | group_by(.) | max_by(length) | .[0]' -r "$ANIMEMAP_CATALOG"/*.json)
year=$(printf %s "$season" | awk '{print $1}')
season=$(printf %s "$season" | awk '{print $2}')
if [[ -z $season ]] || [[ -z $year ]]
then
	printf "%s - Error can't work out the current season stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	exit 1
fi
printf "%s - Current season : %s %s\n\n" "$(date +%H:%M:%S)" "$season" "$year" | tee -a "$LOG"
printf "%s - Creating seasonal list\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s\t - Reading the season from the AnimeMap catalog\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
jq -s --arg season "$season" --argjson year "$year" --argjson limit "$DOWNLOAD_LIMIT" '[ .[]
	| select( .season == $season and .season_year == $year and .format == "TV" ) ]
	| sort_by( - ( .average_score // 0 ) ) | .[0:$limit] | .[].anilist_id' -r "$ANIMEMAP_CATALOG"/*.json > "$SCRIPT_FOLDER/config/tmp/seasonal-animemap.tsv"
printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s\t - Sorting seasonal list\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
while read -r anilist_id
do
	tvdb_id=a
	tvdb_season=-a
	tvdb_epoffset=a
	tvdb_id=$(get-tvdb-id)
	if [[ "$tvdb_id" == 'null' ]] || [[ "${#tvdb_id}" == '0' ]]
	then
		printf "%s\t\t - Seasonal invalid TVDB ID for Anilist : %s\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
		continue
	else
		tvdb_season=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | .tvdb_season' -r "$ANIMEMAP_ANIMES_ID")
		tvdb_epoffset=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | .tvdb_epoffset' -r "$ANIMEMAP_ANIMES_ID")
		if [[ "$tvdb_season" -eq 1 ]] && [[ "$tvdb_epoffset" -eq 0 ]]
		then
			printf "%s\n" "$tvdb_id" >> "$SCRIPT_FOLDER/config/data/seasonal.tsv"
			printf "%s\t\t - New seasonal anime adding to list : Anilist id : %s / tvdb id : %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$tvdb_id" | tee -a "$LOG"
		else
			printf "%s\t\t - Sequel seasonal anime not adding to list : Anilist id : %s / tvdb id : %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$tvdb_id" | tee -a "$LOG"
		fi
	fi
done < "$SCRIPT_FOLDER/config/tmp/seasonal-animemap.tsv"
printf "%s - Done\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"


tvdb_list=$(awk '{printf("%s, ",$0 )}' "$SCRIPT_FOLDER/config/data/seasonal.tsv" | sed 's/,\s*$//')
printf "%s - Wrinting seasonal collection\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s - Seasonal list : tvdb id added : %s\n" "$(date +%H:%M:%S)" "$tvdb_list"| tee -a "$LOG"
printf "collections:\n  seasonal animes download:\n    tvdb_show: %s\n    sync_mode: append\n    sonarr_add_missing: true\n    build_collection: false\n" "$tvdb_list" > "$DOWNLOAD_ANIMES_COLLECTION"
printf "%s - Done\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s - Run finished\n\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"