#!/bin/bash

SCRIPT_FOLDER=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
media_type="animes"
source "$SCRIPT_FOLDER/config/.env"
source "$SCRIPT_FOLDER/VERSION"
source "$SCRIPT_FOLDER/functions.sh"
METADATA=$METADATA_ANIMES
OVERRIDE=override-ID-$media_type.tsv

# check if files and folder exist
if [ ! -d "$SCRIPT_FOLDER/config/data" ]										#check if exist and create folder for json data
then
	mkdir "$SCRIPT_FOLDER/config/data"
else
	find "$SCRIPT_FOLDER/config/data/" -type f -mtime +"$DATA_CACHE_TIME" -exec rm {} \;					#delete json data if older than 2 days
fi
if [ ! -d "$SCRIPT_FOLDER/config/tmp" ]										#check if exist and create folder for json data
then
	mkdir "$SCRIPT_FOLDER/config/tmp"
fi
if [ ! -d "$SCRIPT_FOLDER/config/ID" ]											#check if exist and create folder and file for ID
then
	mkdir "$SCRIPT_FOLDER/config/ID"
fi
if [ ! -d "$LOG_FOLDER" ]
then
	mkdir "$LOG_FOLDER"
fi
:> "$SCRIPT_FOLDER/config/ID/animes.tsv"
:> "$MATCH_LOG"
printf "%s - Starting animes script\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"

# Download the AnimeMap id mapping and catalog
download-animemap-data

# export animes list from plex
printf "%s - Creating animes list\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s\t - Exporting Plex animes library\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
if [ -f "$SCRIPT_FOLDER/romaji-renamer-venv/bin/python3" ]
then
	"$SCRIPT_FOLDER/romaji-renamer-venv/bin/python3" "$SCRIPT_FOLDER/plex_animes_export.py"
else
	python3 "$SCRIPT_FOLDER/plex_animes_export.py"
fi
printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"

# create ID/animes.tsv
create-override
printf "%s\t - Sorting Plex animes library\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
ignore_list=""
while IFS= read -r line
do
	tvdb_id=$(printf "%s" "$line" | awk -F"\t" '{print $1}')
	anilist_id=$(printf "%s" "$line" | awk -F"\t" '{print $2}')
	title_override=$(printf "%s" "$line" | awk -F"\t" '{print $3}')
	studio=$(printf "%s" "$line" | awk -F"\t" '{print $4}')
	override_seasons_ignore=$(printf "%s" "$line" | awk -F"\t" '{print $5}')
	if ! awk -F"\t" '{print $1}' "$SCRIPT_FOLDER/config/ID/animes.tsv" | grep -q -w "$tvdb_id"
	then
		if awk -F"\t" '{print $1}' "$SCRIPT_FOLDER/config/tmp/plex_animes_export.tsv" | grep -q -w "$tvdb_id"
		then
			if [[ "$anilist_id" == 'ignore' ]]
			then
				if [ -z "$ignore_list" ]
				then
					ignore_list="$tvdb_id"
				else
					ignore_list=$(printf "%s,%s" "$ignore_list" "$tvdb_id")
				fi
			else
				line=$(awk -F"\t" '{print $1}' "$SCRIPT_FOLDER/config/tmp/plex_animes_export.tsv" | grep -w -n "$tvdb_id" | cut -d : -f 1)
				plex_title=$(sed -n "${line}p" "$SCRIPT_FOLDER/config/tmp/plex_animes_export.tsv" | awk -F"\t" '{print $2}')
				asset_name=$(sed -n "${line}p" "$SCRIPT_FOLDER/config/tmp/plex_animes_export.tsv" | awk -F"\t" '{print $3}')
				seasons_list=$(sed -n "${line}p" "$SCRIPT_FOLDER/config/tmp/plex_animes_export.tsv" | awk -F"\t" '{print $4}')
				printf "%s\t\t - Found override for tvdb id : %s / anilist id : %s\n" "$(date +%H:%M:%S)" "$tvdb_id" "$anilist_id" | tee -a "$LOG"
				printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$tvdb_id" "$anilist_id" "$plex_title" "$asset_name" "$seasons_list" "$override_seasons_ignore" >> "$SCRIPT_FOLDER/config/ID/animes.tsv"
			fi
		fi
	fi
done < "$SCRIPT_FOLDER/config/override-ID-animes.tsv"
while IFS=$'\t' read -r tvdb_id plex_title asset_name last_season total_seasons 		# then get the other ID from the ID mapping and download json data
do
	if ! awk -F"\t" '{print $1}' "$SCRIPT_FOLDER/config/ID/animes.tsv" | grep -q -w "$tvdb_id"
	then
		anilist_id=$(get-anilist-id)
		if [[ "$anilist_id" == 'null' ]] || [[ "${#anilist_id}" == '0' ]]				# Ignore anime with no anilist id
		then
			if echo "$ignore_list" | grep -q -w "$tvdb_id"
			then
				printf "%s\t\t - Found ignored tvdb id : %s\n" "$(date +%H:%M:%S)" "$tvdb_id" | tee -a "$LOG"
			else
				printf "%s\t\t - Missing Anilist ID for tvdb : %s / %s\n" "$(date +%H:%M:%S)" "$tvdb_id" "$plex_title" | tee -a "$LOG"
				printf "%s - Missing Anilist ID for tvdb : %s / %s\n" "$(date +%H:%M:%S)" "$tvdb_id" "$plex_title" >> "$MATCH_LOG"
			fi
		else
			printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$tvdb_id" "$anilist_id" "$plex_title" "$asset_name" "$last_season" "$total_seasons" >> "$SCRIPT_FOLDER/config/ID/animes.tsv"
		fi
	fi
done < "$SCRIPT_FOLDER/config/tmp/plex_animes_export.tsv"
printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "%s - Done\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"

# Create an ongoing list at $SCRIPT_FOLDER/config/data/ongoing.tsv
printf "%s - Creating AnimeMap airing list\n" "$(date +%H:%M:%S)"
:> "$SCRIPT_FOLDER/config/data/ongoing.tsv"
:> "$SCRIPT_FOLDER/config/tmp/ongoing-tmp.tsv"
ongoingoffset=0
ongoingtotal=0
ongoingcount=0
while true;																		# get every releasing anime from the AnimeMap API
do
	printf "%s\t - Downloading AnimeMap airing list from : %s\n" "$(date +%H:%M:%S)" "$ongoingoffset" | tee -a "$LOG"
	if ! animemap-api-get "$ANIMEMAP_API_URL/mapping/browse?sort=anilist_id&limit=$ANIMEMAP_PAGE_SIZE&offset=$ongoingoffset&status=RELEASING" "$SCRIPT_FOLDER/config/tmp/ongoing-animemap.json"
	then
		printf "%s - Error can't download the AnimeMap airing list stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		exit 1
	fi
	ongoingtotal=$(jq -r '.total // 0' "$SCRIPT_FOLDER/config/tmp/ongoing-animemap.json")
	ongoingcount=$(jq -r '.entries | length' "$SCRIPT_FOLDER/config/tmp/ongoing-animemap.json")
	jq '.entries[].anilist_id' -r "$SCRIPT_FOLDER/config/tmp/ongoing-animemap.json" >> "$SCRIPT_FOLDER/config/tmp/ongoing-tmp.tsv"		# store the anilist ID of the ongoing show
	ongoingoffset=$((ongoingoffset + ongoingcount))
	printf "%s\t - done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	if [[ $ongoingcount -eq 0 ]] || [[ $ongoingoffset -ge $ongoingtotal ]]		# stop if page is empty
	then
		break
	fi
done
	printf "%s\t - Sorting AnimeMap airing list \n" "$(date +%H:%M:%S)" | tee -a "$LOG"
sort -n "$SCRIPT_FOLDER/config/tmp/ongoing-tmp.tsv" | uniq > "$SCRIPT_FOLDER/config/tmp/ongoing.tsv"
while read -r anilist_id
do
	if awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/ID/animes.tsv" | grep -q -w "$anilist_id"
	then
		line=$(awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/ID/animes.tsv" | grep -w -n "$anilist_id" | cut -d : -f 1)
		tvdb_id=$(sed -n "${line}p" "$SCRIPT_FOLDER/config/ID/animes.tsv" | awk -F"\t" '{print $1}')
		printf "%s\n" "$tvdb_id" >> "$SCRIPT_FOLDER/config/data/ongoing.tsv"
	else
		tvdb_id=$(get-tvdb-id)																	# convert the anilist id to tvdb id (to get the main anime)
		if [[ "$tvdb_id" == 'null' ]] || [[ "${#tvdb_id}" == '0' ]]										# Ignore anime with no anilist to tvdb id conversion
		then
			printf "%s\t\t - Ongoing list missing TVDB ID for Anilist : %s\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
			continue
		else
			printf "%s\n" "$tvdb_id" >> "$SCRIPT_FOLDER/config/data/ongoing.tsv"
		fi
	fi
done < "$SCRIPT_FOLDER/config/tmp/ongoing.tsv"
printf "%s\t - Done\n" "$(date +%H:%M:%S)"
printf "%s - Done\n\n" "$(date +%H:%M:%S)"

# write PMM metadata file from ID/animes.tsv and the AnimeMap API
printf "%s - Start writing the metadata file \n" "$(date +%H:%M:%S)" | tee -a "$LOG"
printf "# Romaji-Renamer v%s\n" "$version" > "$METADATA"
printf "metadata:\n" >> "$METADATA"
tvdb_id=""
anilist_id=""
mal_id=""
while IFS=$'\t' read -r tvdb_id anilist_id plex_title asset_name seasons_list override_seasons_ignore
do
	printf "%s\t - Writing metadata for %s / tvdb : %s / Anilist : %s \n" "$(date +%H:%M:%S)" "$plex_title" "$tvdb_id" "$anilist_id" | tee -a "$LOG"
	write-metadata
	printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
done < "$SCRIPT_FOLDER/config/ID/animes.tsv"
printf "%s - Run finished\n\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
exit 0