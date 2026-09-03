#!/bin/bash

#General variables
LOG=$LOG_FOLDER/RR_$(date +%Y.%m.%d).log
MATCH_LOG=$LOG_FOLDER/${media_type}-missing-id.log

#AnimeMap API (https://animemap.dev/docs)
ANIMEMAP_API_URL=${ANIMEMAP_API_URL:-https://mapping.animemap.dev/api/v1}
ANIMEMAP_API_KEY=${ANIMEMAP_API_KEY:-}
ANIMEMAP_API_RETRY=${ANIMEMAP_API_RETRY:-4}
ANILIST_TAGS_P=${ANILIST_TAGS_P:-70}
ANIMEMAP_PAGE_SIZE=100
ANIMEMAP_EXPORT="$SCRIPT_FOLDER/config/tmp/animemap-export.json"
ANIMEMAP_ANIMES_ID="$SCRIPT_FOLDER/config/tmp/animemap-animes-id.json"
ANIMEMAP_MOVIES_ID="$SCRIPT_FOLDER/config/tmp/animemap-movies-id.json"
ANIMEMAP_AWARDS="$SCRIPT_FOLDER/config/tmp/animemap-awards.json"
ANIMEMAP_CATALOG="$SCRIPT_FOLDER/config/tmp/animemap-catalog.json"

# functions
function create-override () {
	if [ ! -f "$SCRIPT_FOLDER/config/$OVERRIDE" ]
	then
		cp "$SCRIPT_FOLDER/config/override-ID-${media_type}.example.tsv" "$SCRIPT_FOLDER/config/$OVERRIDE"
	fi
}
function animemap-api-get () {															# $1 url / $2 output file, 0 = ok, 1 = failed, 2 = not found
	local url="$1"
	local output="$2"
	local try=0
	local http_code=""
	local -a api_key_header=()
	if [[ -n $ANIMEMAP_API_KEY ]]														# the key travels in a header, never in the url, so it stays out of the logs
	then
		api_key_header=(-H "X-API-Key: $ANIMEMAP_API_KEY")
	fi
	while [ $try -lt "$ANIMEMAP_API_RETRY" ];
	do
		http_code=$(curl -s --max-time 300 "${api_key_header[@]}" -o "$output" -w "%{http_code}" "$url")
		if [[ $http_code == "200" ]]
		then
			return 0
		elif [[ $http_code == "404" ]]
		then
			return 2
		elif [[ $http_code == "401" ]] || [[ $http_code == "403" ]]						# a credential problem never fixes itself, don't burn the retries on it
		then
			if [[ -z $ANIMEMAP_API_KEY ]]
			then
				printf "%s - The AnimeMap deployment requires an API key, set ANIMEMAP_API_KEY in your .env (create one at %s/auth/keys)\n" "$(date +%H:%M:%S)" "$ANIMEMAP_API_URL" | tee -a "$LOG"
			else
				printf "%s - The AnimeMap API refused the key in ANIMEMAP_API_KEY (%s)\n" "$(date +%H:%M:%S)" "$http_code" | tee -a "$LOG"
			fi
			rm -f "$output"
			return 1
		fi
		((try++))
		if [ $try -lt "$ANIMEMAP_API_RETRY" ]
		then
			printf "%s\t\t - AnimeMap API answered %s for %s, waiting 30s\n" "$(date +%H:%M:%S)" "$http_code" "$url" | tee -a "$LOG"
			sleep 30
		fi
	done
	rm -f "$output"
	return 1
}
function download-animemap-data () {
	printf "%s - Downloading AnimeMap export\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	if ! animemap-api-get "$ANIMEMAP_API_URL/export.json" "$ANIMEMAP_EXPORT"
	then
		printf "%s - Error can't download the AnimeMap export stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		exit 1
	fi
	size=$(du -b "$ANIMEMAP_EXPORT" | awk '{ print $1 }')
	if [[ $size -lt 1000 ]]
	then
		printf "%s - Error the AnimeMap export is empty stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		exit 1
	fi
	printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	printf "%s - Building the animes and movies id maps\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	# a tvdb season of "a" (absolute numbering) or none at all is kept as "-1", the value the season logic uses for "not split per tvdb season"
	if ! jq -c '[ .entries[]
		| select( .anilist_id != null and .tvdb.id != null )
		| { tvdb_id: ( .tvdb.id | tostring ),
			tvdb_season: ( if ( .tvdb.season | type ) == "number" then ( .tvdb.season | tostring ) else "-1" end ),
			tvdb_epoffset: ( ( .tvdb.episode_offset // 0 ) | tostring ),
			anidb_id: ( ( .anidb.id // "" ) | tostring ),
			mal_id: ( ( .mal.id // "" ) | tostring ),
			anilist_id: ( .anilist_id | tostring ) } ]' "$ANIMEMAP_EXPORT" > "$ANIMEMAP_ANIMES_ID"
	then
		printf "%s - Error can't read the AnimeMap export stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		exit 1
	fi
	# only the entries a plex movies library can hold, so a serie imdb id never matches a movie
	jq -c '[ .entries[]
		| select( .anilist_id != null and .imdb.id != null )
		| select( .format == "MOVIE" or .tmdb.media_type == "movie" )
		| { imdb_id: .imdb.id,
			anidb_id: ( ( .anidb.id // "" ) | tostring ),
			mal_id: ( ( .mal.id // "" ) | tostring ),
			anilist_id: ( .anilist_id | tostring ) } ]' "$ANIMEMAP_EXPORT" > "$ANIMEMAP_MOVIES_ID"
	jq -c '[ .entries[]
		| select( .anilist_id != null )
		| { anilist_id: ( .anilist_id | tostring ), awards: .crunchyroll_awards }
		| .anilist_id as $anilist_id
		| .awards[]?
		| { anilist_id: $anilist_id, year: ( .year | tostring ), cr_award: .award } ]' "$ANIMEMAP_EXPORT" > "$ANIMEMAP_AWARDS"
	rm -f "$ANIMEMAP_EXPORT"
	printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	download-animemap-catalog
}
function download-animemap-catalog () {													# the metadata (titles, score, genres, studios, season, status, poster) of the whole catalog
	local pages="$SCRIPT_FOLDER/config/tmp/animemap-catalog-pages.json"
	local page="$SCRIPT_FOLDER/config/tmp/animemap-catalog-page.json"
	local offset=0
	local total=0
	local count=0
	printf "%s - Downloading the AnimeMap catalog\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	:> "$pages"
	while true;
	do
		if ! animemap-api-get "$ANIMEMAP_API_URL/mapping/browse?sort=anilist_id&limit=$ANIMEMAP_PAGE_SIZE&offset=$offset" "$page"
		then
			printf "%s - Error can't download the AnimeMap catalog stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
			exit 1
		fi
		total=$(jq -r '.total // 0' "$page")
		count=$(jq -r '.entries | length' "$page")
		jq -c '.entries[]' "$page" >> "$pages"
		offset=$((offset + count))
		if [[ $count -eq 0 ]] || [[ $offset -ge $total ]]
		then
			break
		fi
		if [[ $((offset % 2000)) -lt $ANIMEMAP_PAGE_SIZE ]]
		then
			printf "%s\t - %s / %s entries\n" "$(date +%H:%M:%S)" "$offset" "$total" | tee -a "$LOG"
		fi
	done
	printf "%s\t - Sorting the AnimeMap catalog\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	jq -s -c 'map( { key: ( .anilist_id | tostring ),
		value: { anilist_id: .anilist_id,
			title_romaji: .title_romaji,
			title_english: .title_english,
			title_native: .title_native,
			format: .format,
			episodes: .episodes,
			season_year: .season_year,
			season: .season,
			status: .status,
			average_score: .average_score,
			genres: ( .genres // [] ),
			tags: null,																	# browse serves 10 tags and hides the spoilers, get-anilist-tags-full fetches the real list
			studios: ( .studios // [] ),
			cover_image: .cover_image,
			mal_id: .mal_id,
			tvdb_id: .tvdb_id } } ) | from_entries' "$pages" > "$ANIMEMAP_CATALOG"
	rm -f "$pages" "$page"
	printf "%s\t - Done\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
}
function get-anilist-userlist {															# the one call left to the anilist API, AnimeMap serves no per user list
	if [[ $ANILIST_LISTS == "Yes" ]]
	then
		printf "%s - Creating Anilist userlist for : %s\n" "$(date +%H:%M:%S)" "$ANILIST_USERNAME" | tee -a "$LOG"
		wait_time=0
		anilist_api_retry=0
		while [ $wait_time -lt 5 ] || [ $anilist_api_retry -lt 5 ];
		do
			printf "%s\t - Downloading Anilist userlist\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
			curl -s 'https://graphql.anilist.co/' \
			-X POST \
			-H 'content-type: application/json' \
			--data '{ "query": "{ MediaListCollection(userName: \"'"$ANILIST_USERNAME"'\" type:ANIME) {  lists {    name    entries {      mediaId    }  }}}" }' > "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json" -D "$SCRIPT_FOLDER/config/tmp/anilist-limit-rate.txt"
			if grep -q -w '"data": null' "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json"
			then
				((anilist_api_retry++))
				rm "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json"
				printf "%s - Invalid json from AniList API down, waiting 60s\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
				sleep 61
			fi
			rate_limit=0
			rate_limit=$(grep -oP '(?<=x-ratelimit-remaining: )[0-9]+' "$SCRIPT_FOLDER/config/tmp/anilist-limit-rate.txt")
			((wait_time++))
			if [[ $wait_time == 4 ]] || [[ $anilist_api_retry == 4 ]]
			then
				printf "%s - Error can't download anilist data stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
				exit 1
			elif [[ -z $rate_limit ]]
			then
				printf "%s\t - Cloudflare limit rate reached watiting 60s\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
				sleep 61
			elif [[ $rate_limit -ge 3 ]]
			then
				sleep 1
				printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
				break
			elif [[ $rate_limit -lt 3 ]]
			then
				printf "%s\t - Anilist API limit reached watiting 30s" "$(date +%H:%M:%S)" | tee -a "$LOG"
				sleep 30
				printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
				break
			fi
		done
		printf "%s\t - Sorting Anilist userlist\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		jq '.data.MediaListCollection.lists | .[] | select( .name == "Completed" ) | .entries | .[].mediaId ' -r "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json" | paste -s -d, - > "$SCRIPT_FOLDER/config/data/anilist-$ANILIST_USERNAME-Completed.tsv"
		jq '.data.MediaListCollection.lists | .[] | select( .name == "Watching" ) | .entries | .[].mediaId ' -r "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json" | paste -s -d, - > "$SCRIPT_FOLDER/config/data/anilist-$ANILIST_USERNAME-Watching.tsv"
		jq '.data.MediaListCollection.lists | .[] | select( .name == "Dropped" ) | .entries | .[].mediaId ' -r "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json" | paste -s -d, - > "$SCRIPT_FOLDER/config/data/anilist-$ANILIST_USERNAME-Dropped.tsv"
		jq '.data.MediaListCollection.lists | .[] | select( .name == "Paused" ) | .entries | .[].mediaId ' -r "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json" | paste -s -d, - > "$SCRIPT_FOLDER/config/data/anilist-$ANILIST_USERNAME-Paused.tsv"
		jq '.data.MediaListCollection.lists | .[] | select( .name == "Planning" ) | .entries | .[].mediaId ' -r "$SCRIPT_FOLDER/config/tmp/anilist-$ANILIST_USERNAME.json" | paste -s -d, - > "$SCRIPT_FOLDER/config/data/anilist-$ANILIST_USERNAME-Planning.tsv"
		printf "%s\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		printf "%s - done\n\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	fi
}
function get-anilist-id () {
	if [[ $media_type == "animes" ]]
	then
		jq --arg tvdb_id "$tvdb_id" '.[] | select( .tvdb_id == $tvdb_id ) | select( .tvdb_season == "1" or .tvdb_season == "-1" ) | select( .tvdb_epoffset == "0" ) | .anilist_id' -r "$ANIMEMAP_ANIMES_ID" | head -n 1
	else
		jq --arg imdb_id "$imdb_id" '.[] | select( .imdb_id == $imdb_id ) | .anilist_id' -r "$ANIMEMAP_MOVIES_ID" | head -n 1
	fi
}
function get-mal-id () {
	get-animemap-infos
	mal_id=$(jq '.mal_id' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	if [[ $mal_id == 'null' ]] || [[ -z $mal_id ]]
	then
		if [[ $media_type == "animes" ]]
		then
			mal_id=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | .mal_id' -r "$ANIMEMAP_ANIMES_ID" | head -n 1)
		else
			mal_id=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | .mal_id' -r "$ANIMEMAP_MOVIES_ID" | head -n 1)
		fi
	fi
}
function get-tvdb-id () {
	jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | .tvdb_id' -r "$ANIMEMAP_ANIMES_ID"
}
function animemap-empty-record () {														# a full record with every field null, so a getter reading it never trips on a missing key
	jq -n -c --arg anilist_id "$1" '{ anilist_id: ( $anilist_id | if . == "" then null else tonumber? end ),
		title_romaji: null,
		title_english: null,
		title_native: null,
		format: null,
		episodes: null,
		season_year: null,
		season: null,
		status: null,
		average_score: null,
		genres: [],
		tags: null,
		studios: [],
		cover_image: null,
		mal_id: null,
		tvdb_id: null }'
}
function get-animemap-infos () {														# cache the catalog entry of $anilist_id at config/data/animemap-$anilist_id.json
	local data_file="$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json"
	local api_file="$SCRIPT_FOLDER/config/tmp/animemap-mapping.json"
	local api_status=0
	if [[ -z $anilist_id ]] || [[ $anilist_id == "null" ]]
	then
		animemap-empty-record "" > "$data_file"
		return 1
	fi
	if [ -f "$data_file" ]
	then
		return 0
	fi
	if [ -f "$ANIMEMAP_CATALOG" ]
	then
		jq -c --arg anilist_id "$anilist_id" '.[$anilist_id] // empty' "$ANIMEMAP_CATALOG" > "$data_file"
		if [ -s "$data_file" ]
		then
			return 0
		fi
	fi
	rm -f "$data_file"
	if [[ $cours_count_total -gt 1 ]]
	then
		printf "%s\t\t - Downloading data for S%s part-%s animemap : %s\n" "$(date +%H:%M:%S)" "$season_number" "$cours_count" "$anilist_id" | tee -a "$LOG"
	elif [[ "$season_loop" == 1 ]]
	then
		printf "%s\t\t - Downloading data for S%s animemap : %s\n" "$(date +%H:%M:%S)" "$season_number" "$anilist_id" | tee -a "$LOG"
	else
		printf "%s\t\t - Downloading data for animemap : %s\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
	fi
	animemap-api-get "$ANIMEMAP_API_URL/mapping/anilist/$anilist_id?include_spoilers=true" "$api_file"
	api_status=$?
	if [[ $api_status == 1 ]]
	then
		printf "%s - Error can't download animemap data stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		exit 1
	fi
	if [[ $api_status == 2 ]]
	then																				# the catalog holds no entry for that id, keep an empty record so the run carries on
		printf "%s\t\t - Unknown Anilist id on AnimeMap : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" | tee -a "$LOG"
		printf "%s - Unknown Anilist id on AnimeMap : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" >> "$MATCH_LOG"
		animemap-empty-record "$anilist_id" > "$data_file"
		return 0
	fi
	# the per id endpoint carries no studio and no anilist season, they only exist on the catalog
	jq -c '.mapping | { anilist_id: .anilist.anilist_id,
		title_romaji: .anilist.title_romaji,
		title_english: .anilist.title_english,
		title_native: .anilist.title_native,
		format: .anilist.format,
		episodes: .anilist.episodes,
		season_year: .anilist.season_year,
		season: null,
		status: .anilist.status,
		average_score: .anilist.average_score,
		genres: ( .anilist.genres // [] ),
		tags: [ .anilist.tags[]? | { name, rank } ],
		studios: [],
		cover_image: .anilist.cover_image,
		mal_id: .mal.id,
		tvdb_id: .tvdb.id }' "$api_file" > "$data_file"
	rm -f "$api_file"
	printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
}
function get-mal-infos () {																# the MyAnimeList data AnimeMap serves alongside a mapping, a raw jikan data object
	mal_id=""
	get-mal-id
	if [[ $mal_id == 'null' ]] || [[ -z $mal_id ]]
	then
		printf "%s\t\t - Missing MAL ID for Anilist : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" | tee -a "$LOG"
		printf "%s - Missing MAL ID for Anilist : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" >> "$MATCH_LOG"
		return 0
	fi
	local mal_file="$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json"
	local api_file="$SCRIPT_FOLDER/config/tmp/animemap-mal-mapping.json"
	if [ -f "$mal_file" ]
	then
		return 0
	fi
	if [[ $cours_count_total -gt 1 ]]
	then
		printf "%s\t\t - Downloading data for S%s part-%s MAL : %s\n" "$(date +%H:%M:%S)" "$season_number" "$cours_count" "$mal_id" | tee -a "$LOG"
	elif [[ "$season_loop" == 1 ]]
	then
		printf "%s\t\t - Downloading data for S%s MAL : %s\n" "$(date +%H:%M:%S)" "$season_number" "$mal_id" | tee -a "$LOG"
	else
		printf "%s\t\t - Downloading data for MAL : %s\n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG"
	fi
	if ! animemap-api-get "$ANIMEMAP_API_URL/mapping/anilist/$anilist_id?include_spoilers=true" "$api_file"
	then
		printf "%s\t\t - Can't download MAL data for : %s skipping\n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG"
		return 0
	fi
	if jq -e '.mapping.mal.data == null' "$api_file" > /dev/null					# a miss is never cached, MAL is an upstream AnimeMap calls live
	then
		printf "%s\t\t - No MAL data returned for : %s / %s\n" "$(date +%H:%M:%S)" "$mal_id" "$(jq -r '( .warnings // [] ) | join(" ")' "$api_file")" | tee -a "$LOG"
		printf "%s - No MAL data returned for : %s / %s\n" "$(date +%H:%M:%S)" "$mal_id" "$plex_title" >> "$MATCH_LOG"
		rm -f "$api_file"
		return 0
	fi
	jq -c '{ data: .mapping.mal.data }' "$api_file" > "$mal_file"
	rm -f "$api_file"
	printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
}
function get-romaji-title () {
	title="null"
	title_tmp="null"
	if awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/$OVERRIDE" | grep -q -w "$anilist_id"
	then
		line=$(awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/$OVERRIDE" | grep -w -n "$anilist_id" | cut -d : -f 1)
		title_tmp=$(sed -n "${line}p" "$SCRIPT_FOLDER/config/$OVERRIDE" | awk -F"\t" '{print $3}')
		if [[ -z "$title_tmp" ]]
		then
			title=$(jq '.title_romaji' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
			less-caps-title
			echo "$title"
		else
			title="$title_tmp"
			less-caps-title
			echo "$title"
		fi
	else
		title=$(jq '.title_romaji' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
		less-caps-title
		echo "$title"
	fi
}
function get-english-title () {
	title="null"
	title_tmp="null"
	if awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/$OVERRIDE" | grep -q -w "$anilist_id"
	then
		line=$(awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/$OVERRIDE" | grep -w -n "$anilist_id" | cut -d : -f 1)
		title_tmp=$(sed -n "${line}p" "$SCRIPT_FOLDER/config/$OVERRIDE" | awk -F"\t" '{print $3}')
		if [[ -z "$title_tmp" ]]
		then
			title=$(jq '.title_english' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
			less-caps-title
			echo "$title"
		else
			title="$title_tmp"
			less-caps-title
			echo "$title"
		fi
	else
		title=$(jq '.title_english' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
		less-caps-title
		echo "$title"
	fi
}
function get-native-title () {
	title=$(jq '.title_native' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	echo "$title"
}
function less-caps-title () {
	if [[ $REDUCE_TITLE_CAPS == "Yes" ]]
	then
		upper_check=$(echo "$title" | sed -e "s/[^ a-zA-Z]//g" -e 's/ //g')
		if [[ "$upper_check" =~ ^[A-Z]+$ ]]
		then
			title=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed "s/\( \|^\)\(.\)/\1\u\2/g")
		fi
	fi
}
function get-score () {
	anime_score=0
	get-animemap-infos
	anime_score=$(jq '.average_score' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	if [[ "$anime_score" == "null" ]] || [[ "$anime_score" == "" ]]
	then
		anime_score=0
	else
		anime_score=$(printf %s "$anime_score" | awk '{print $1 / 10}')
	fi
}
function get-mal-score () {
	anime_score=0
	mal_id=""
	get-mal-id
	if [[ $mal_id == 'null' ]] || [[ -z $mal_id ]]
	then
		printf "%s\t\t - Missing MAL ID for Anilist : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" | tee -a "$LOG"
		printf "%s - Missing MAL ID for Anilist : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" >> "$MATCH_LOG"
		return 0
	fi
	get-mal-infos
	if [ -f "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json" ]
	then
		anime_score=$(jq '.data.score' -r "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json")
	fi
	if [[ "$anime_score" == "null" ]] || [[ "$anime_score" == "" ]]
	then
		anime_score=0
	fi
}
function get-anilist-tags-full () {														# the tags of $anilist_id, spoilers included, straight from the per id endpoint
	local data_file="$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json"
	local api_file="$SCRIPT_FOLDER/config/tmp/animemap-tags.json"
	local tags_mal_id=""
	local tags_mal_file=""
	if ! jq -e '.tags == null' "$data_file" > /dev/null								# a null tag list is one that was never fetched
	then
		return 0
	fi
	printf "%s\t\t - Downloading the tags for animemap : %s\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
	if ! animemap-api-get "$ANIMEMAP_API_URL/mapping/anilist/$anilist_id?include_spoilers=true" "$api_file"
	then
		printf "%s\t\t - Can't download the tags for : %s skipping\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
		return 0
	fi
	jq -c --slurpfile mapping "$api_file" '.tags = [ $mapping[0].mapping.anilist.tags[]? | { name, rank } ]' "$data_file" > "$data_file.tmp" && mv "$data_file.tmp" "$data_file"
	tags_mal_id=$(jq '.mapping.mal.id // empty' -r "$api_file")						# the same answer carries the MAL data, keep it rather than asking twice
	if [[ -n $tags_mal_id ]]
	then
		tags_mal_file="$SCRIPT_FOLDER/config/data/animemap-mal-$tags_mal_id.json"
		if [ ! -f "$tags_mal_file" ] && ! jq -e '.mapping.mal.data == null' "$api_file" > /dev/null
		then
			jq -c '{ data: .mapping.mal.data }' "$api_file" > "$tags_mal_file"
		fi
	fi
	rm -f "$api_file"
	printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
}
function get-animemap-tags () {															# the anilist genres, plus the tags ranked at or above ANILIST_TAGS_P
	get-animemap-infos
	get-anilist-tags-full
	anime_tags=$( (jq '.genres | .[]' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json" && jq --argjson anilist_tags_p "$ANILIST_TAGS_P" '.tags // [] | .[] | select( .rank >= $anilist_tags_p ) | .name' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json") | awk '{print $0}' | paste -sd ',')
}
function get-mal-tags () {
	anime_tags=""
	mal_id=""
	get-mal-id
	if [[ $mal_id == 'null' ]] || [[ -z $mal_id ]]
	then
		printf "%s\t\t - Missing MAL ID for Anilist : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" | tee -a "$LOG"
		printf "%s - Missing MAL ID for Anilist : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" >> "$MATCH_LOG"
		return 0
	fi
	get-mal-infos
	if [ ! -f "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json" ]
	then
		return 0
	fi
	anime_tags=$( (jq '.data.genres | .[]? | .name' -r "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json" && jq '.data.demographics | .[]? | .name' -r "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json" && jq '.data.themes | .[]? | .name' -r "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json") | awk '{print $0}' | paste -sd ',')
}
function get-studios() {
	if awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/$OVERRIDE" | grep -q -w "$anilist_id"
	then
		line=$(awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/$OVERRIDE" | grep -w -n "$anilist_id" | cut -d : -f 1)
		studio=$(sed -n "${line}p" "$SCRIPT_FOLDER/config/$OVERRIDE" | awk -F"\t" '{print $4}')
		if [[ -n "$studio" ]]
		then
			return 0
		fi
	fi
	get-animemap-infos
	studio=$(jq '.studios | .[0] // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	if [[ -n "$studio" ]]
	then
		return 0
	fi
	get-mal-infos																		# the catalog knows no studio for about one entry in six, MAL usually does
	if [ -f "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json" ]
	then
		studio=$(jq '.data.studios | .[0].name // empty' -r "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json")
	fi
}
function get-animes-season-year () {
	anime_season=""
	get-animemap-infos
	year_season=$(jq '.season_year // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	name_season=$(jq '.season // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	if [[ -n "$year_season" ]] && [[ -n "$name_season" ]]
	then
		anime_season=$(printf "%s %s" "$year_season" "$name_season" | tr '[:upper:]' '[:lower:]' | sed "s/\( \|^\)\(.\)/\1\u\2/g")
	fi
}
function get-animes-award () {
	award_check=""
	cr_awards=""
	if [[ $ANIME_AWARDS_NO_FVA == "Yes" ]]
	then
		award_check=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | select(.cr_award | contains("English") or contains("Arabic") or contains("Spanish") or contains("Castilian") or contains("French")or contains("German") or contains("Italian") or contains("Portuguese") or contains("Russian")  | not) | "AA " + .year + " " + .cr_award' -r "$ANIMEMAP_AWARDS" | paste -s -d, -)  > /dev/null
		if [[ -n $award_check ]]
		then
			cr_awards=$award_check
		fi
	else
		award_check=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | "AA " + .year + " " + .cr_award' -r "$ANIMEMAP_AWARDS" | paste -s -d, -)  > /dev/null
		if [[ -n $award_check ]]
		then
			cr_awards=$award_check
		fi
	fi
}
function get-airing-status () {															# AnimeMap carries no anilist relation, a serie counts as planned when any of the entries of its tvdb serie is unreleased
	local IFS=$' \t\n'																		# get-season-infos splits on commas, the ids read below are one per line
	local anilist_backup_id=$anilist_id
	local sequel_ids=""
	local sequel_id=""
	airing_status="Ended"
	get-animemap-infos
	if jq '.status' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json" | grep -q -w "NOT_YET_RELEASED"
	then
		airing_status="Planned"
		return 0
	fi
	if [[ $media_type != "animes" ]] || [[ -z $tvdb_id ]]
	then
		return 0
	fi
	sequel_ids=$(jq --arg tvdb_id "$tvdb_id" '.[] | select( .tvdb_id == $tvdb_id ) | .anilist_id' -r "$ANIMEMAP_ANIMES_ID" | sort -n | uniq)
	for sequel_id in $sequel_ids
	do
		anilist_id=$sequel_id
		get-animemap-infos
		if jq '.status' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json" | grep -q -w "NOT_YET_RELEASED"
		then
			airing_status="Planned"
			break
		fi
	done
	anilist_id=$anilist_backup_id
}
function get-poster-url () {
	poster_url=""
	if [[ $POSTER_SOURCE == "MAL" ]]
	then
		get-mal-infos
		if [ -f "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json" ]
		then
			poster_url=$(jq '.data.images.jpg.large_image_url // empty' -r "$SCRIPT_FOLDER/config/data/animemap-mal-$mal_id.json")
		fi
	else
		get-animemap-infos
		poster_url=$(jq '.cover_image // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	fi
}
function download-poster () {															# $1 destination file, AnimeMap serves the medium anilist cover, the large one lives at the same path
	local destination="$1"
	local large_url=""
	local poster_size=0
	get-poster-url
	if [[ -z "$poster_url" ]]
	then
		return 1
	fi
	large_url=$(printf %s "$poster_url" | sed 's#/cover/medium/#/cover/large/#')
	curl -s "$large_url" -o "$destination"
	poster_size=$(du -b "$destination" | awk '{ print $1 }')
	if [[ $poster_size -lt 10000 ]] && [[ "$large_url" != "$poster_url" ]]
	then
		curl -s "$poster_url" -o "$destination"
	fi
	sleep 0.5
	return 0
}
function get-poster () {
	if [[ $POSTER_DOWNLOAD != "Yes" ]]
	then
		return 0
	fi
	local poster_file="$ASSET_FOLDER/$asset_name/poster.jpg"
	if [ -f "$poster_file" ]
	then
		postersize=$(du -b "$poster_file" | awk '{ print $1 }')
		if [[ $postersize -ge 10000 ]]
		then
			return 0
		fi
		rm -f "$poster_file"
	fi
	mkdir -p "$ASSET_FOLDER/$asset_name"
	if [[ $POSTER_SOURCE == "MAL" ]]
	then
		printf "%s\t\t - Downloading poster for MAL : %s\n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG"
	else
		printf "%s\t\t - Downloading poster for animemap : %s\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
	fi
	if download-poster "$poster_file"
	then
		printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	else
		printf "%s\t\t - No poster found skipping\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	fi
}
function get-season-poster () {
	if [[ $POSTER_SEASON_DOWNLOAD != "Yes" ]]
	then
		return 0
	fi
	if [[ $season_number -lt 10 ]]
	then
		assets_filepath="$ASSET_FOLDER/$asset_name/Season0$season_number.jpg"
	else
		assets_filepath="$ASSET_FOLDER/$asset_name/Season$season_number.jpg"
	fi
	if [ -f "$assets_filepath" ]
	then
		postersize=$(du -b "$assets_filepath" | awk '{ print $1 }')
		if [[ $postersize -ge 10000 ]]
		then
			return 0
		fi
		rm -f "$assets_filepath"
	fi
	mkdir -p "$ASSET_FOLDER/$asset_name"
	if [[ $POSTER_SOURCE == "MAL" ]]
	then
		printf "%s\t\t - Downloading poster for S%s MAL : %s\n" "$(date +%H:%M:%S)" "$season_number" "$mal_id" | tee -a "$LOG"
	else
		printf "%s\t\t - Downloading poster for S%s animemap : %s\n" "$(date +%H:%M:%S)" "$season_number" "$anilist_id" | tee -a "$LOG"
	fi
	if download-poster "$assets_filepath"
	then
		printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	else
		printf "%s\t\t - No poster found skipping\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
	fi
}
function get-rating-1 () {
	if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
	then
		if [[ $RATING_1_SOURCE == "ANILIST" ]]
		then
			get-score
			score_1=$anime_score
		else
			get-mal-score
			score_1=$anime_score
		fi
	fi
	if [[ "$score_1" == 0 ]]
	then
		if [[ $RATING_1_SOURCE == "ANILIST" ]]
		then
			printf "%s\t\t - invalid rating for Anilist : %s skipping \n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
		else 
			printf "%s\t\t - invalid rating for MAL : %s skipping \n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG"
		fi
	else
		score_1=$(printf '%.*f\n' 1 "$score_1")
		printf "    %s_rating: %s\n" "$RATING_1_TYPE" "$score_1" >> "$METADATA"
	fi
}
function get-season-rating-1 () {
	if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
	then
		if [[ $RATING_1_SOURCE == "ANILIST" ]]
		then
			get-score
			score_1_season=$anime_score
		else
			get-mal-score
			score_1_season=$anime_score
		fi
		score_1_season=$(printf '%.*f\n' 1 "$score_1_season")
		if [[ "$score_1_season" == 0.0 ]]
		then
			((score_1_no_rating_seasons++))
		fi
	fi
}
function get-cour-rating-1 () {
	if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
	then
		if [[ $RATING_1_SOURCE == "ANILIST" ]]
		then
			get-score
			score_1_cour=$anime_score
		else
			get-mal-score
			score_1_cour=$anime_score
		fi
		score_1_cour=$(printf '%.*f\n' 1 "$score_1_cour")
		if [[ "$score_1_cour" == 0.0 ]]
		then
			((score_1_no_rating_cours++))
		fi
	fi
}
function total-cour-rating-1 () {
	if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
	then
		total_1_cours_score=$(echo | awk -v v1="$score_1_cour" -v v2="$total_1_cours_score" '{print v1 + v2}')
	fi
}
function total-rating-1 () {
	if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
	then
		total_1_score=$(echo | awk -v v1="$score_1_season" -v v2="$total_1_score" '{print v1 + v2}')
	fi
}
function check-rating-1-valid () {
	if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
	then
		if [[ "$score_1" == 0 ]]
		then
			if [[ $RATING_1_SOURCE == "ANILIST" ]]
			then
				printf "%s\t\t - invalid rating for Anilist : %s skipping \n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
			else
				get-mal-id
				if [[ $mal_id != 'null' ]] || [[ -n $mal_id ]]
				then
					printf "%s\t\t - invalid rating for MAL : %s skipping \n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG"
				fi
			fi
		else
			score_1=$(printf '%.*f\n' 1 "$score_1")
			printf "    %s_rating: %s\n" "$RATING_1_TYPE" "$score_1" >> "$METADATA"
		fi
	fi
}
function get-rating-2 () {
	if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
	then
		if [[ $RATING_2_SOURCE == "ANILIST" ]]
		then
			get-score
			score_2=$anime_score
		else
			get-mal-score
			score_2=$anime_score
		fi
	fi
	if [[ "$score_2" == 0 ]]
	then
		if [[ $RATING_2_SOURCE == "ANILIST" ]]
		then
			printf "%s\t\t - invalid rating for Anilist : %s skipping \n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
		else 
			printf "%s\t\t - invalid rating for MAL : %s skipping \n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG"
		fi
	else
		score_2=$(printf '%.*f\n' 1 "$score_2")
		printf "    %s_rating: %s\n" "$RATING_2_TYPE" "$score_2" >> "$METADATA"
	fi
}
function get-season-rating-2 () {
	if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
	then
		if [[ $RATING_2_SOURCE == "ANILIST" ]]
		then
			get-score
			score_2_season=$anime_score
		else
			get-mal-score
			score_2_season=$anime_score
		fi
		score_2_season=$(printf '%.*f\n' 1 "$score_2_season")
		if [[ "$score_2_season" == 0.0 ]]
		then
			((score_2_no_rating_seasons++))
		fi
	fi
}
function get-cour-rating-2 () {
	if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
	then
		if [[ $RATING_2_SOURCE == "ANILIST" ]]
		then
			get-score
			score_2_cour=$anime_score
		else
			get-mal-score
			score_2_cour=$anime_score
		fi
		score_2_cour=$(printf '%.*f\n' 1 "$score_2_cour")
		if [[ "$score_2_cour" == 0.0 ]]
		then
			((score_2_no_rating_cours++))
		fi
	fi
}
function total-cour-rating-2 () {
	if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
	then
		total_2_cours_score=$(echo | awk -v v1="$score_2_cour" -v v2="$total_2_cours_score" '{print v1 + v2}')
	fi
}
function total-rating-2 () {
	if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
	then
		total_2_score=$(echo | awk -v v1="$score_2_season" -v v2="$total_2_score" '{print v1 + v2}')
	fi
}
function check-rating-2-valid () {
	if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
	then
		if [[ "$score_2" == 0 ]]
		then
			if [[ $RATING_2_SOURCE == "ANILIST" ]]
			then
				printf "%s\t\t - invalid rating for Anilist : %s skipping \n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG"
			else
				get-mal-id
				if [[ $mal_id == 'null' ]] || [[ -n $mal_id ]]
				then
					printf "%s\t\t - invalid rating for MAL : %s skipping \n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG"
				fi
			fi
		else
			score_2=$(printf '%.*f\n' 1 "$score_2")
			printf "    %s_rating: %s\n" "$RATING_2_TYPE" "$score_2" >> "$METADATA"
		fi
	fi
}
function get-season-infos () {
	override_id=""
	anilist_backup_id=$anilist_id
	season_check=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | .tvdb_season' -r "$ANIMEMAP_ANIMES_ID")
	first_season=$(echo "$seasons_list" | awk -F "," '{print $1}')
	last_season=$(echo "$seasons_list" | awk -F "," '{print $NF}')
	total_seasons=$(echo "$seasons_list" | awk -F "," '{print NF}')
	valid_anilist_id=$(jq --arg tvdb_id "$tvdb_id" '.[] | select( .tvdb_id == $tvdb_id ) | .anilist_id' -r "$ANIMEMAP_ANIMES_ID")
	if awk -F"\t" '{print $2}' "$SCRIPT_FOLDER/config/$OVERRIDE" | grep -q -w "$anilist_backup_id" && [[ $last_season -eq 1 ]]
	then
		valid_anilist_id=1
		override_id=$anilist_backup_id
	fi
	if [[ "$first_season" -eq 0 ]]
	then
		total_seasons=$((total_seasons - 1))
	fi
	if [ -n "$valid_anilist_id" ] && [[ $season_check != -1 ]]
	then
		total_1_score=0
		total_2_score=0
		score_1_season=0
		score_2_season=0
		score_1_no_rating_seasons=0
		score_2_no_rating_seasons=0
		season_loop=0
		anime_season=""
		award_check=""
		cr_awards=""
		printf "    seasons:\n" >> "$METADATA"
		IFS=","
		for season_number in $seasons_list
		do
			if [[ $season_number -eq 0 ]]
			then
				printf "      0:\n        label.remove: Score\n" >> "$METADATA"
			else
				season_loop=1
				anilist_ids=$(jq --arg tvdb_id "$tvdb_id" --arg season_number "$season_number" '[.[] | select( .tvdb_id == $tvdb_id ) | select( .tvdb_season == $season_number )] | sort_by(.tvdb_epoffset) | .[].anilist_id' -r "$ANIMEMAP_ANIMES_ID" | paste -s -d, -)
				if [ -n "$override_id" ] && [[ $season_number -eq 1 ]]
				then
					anilist_ids=$anilist_backup_id
				fi
				cours_count_total=$(printf %s "$anilist_ids" | awk -F "," '{print NF}')
				total_1_cours_score=0
				total_2_cours_score=0
				score_1_no_rating_cours=0
				score_2_no_rating_cours=0
				cours_count=0
				cour_status=""
				all_cours_anime_season=""
				season_userlist_type_add=""
				seasons_userlist_type_remove=""
				IFS=','
				for anilist_id in $anilist_ids
				do
					((cours_count++))
					if [[ -n "$anilist_id" ]]
					then
						get-animemap-infos
						if jq '.status' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json" | grep -q -w "NOT_YET_RELEASED"
						then
							((score_1_no_rating_cours++))
							((score_2_no_rating_cours++))
							continue
						fi
						if { [[ $ANILIST_LISTS_LEVEL == "season" ]] || [[ $ANILIST_LISTS_LEVEL == "both" ]]; } && [[ $ANILIST_LISTS == "Yes" ]]
						then
							for userlist_type in Completed Watching Dropped Paused Planning
							do
								if grep -q -w "$anilist_id" "$SCRIPT_FOLDER/config/data/anilist-$ANILIST_USERNAME-$userlist_type.tsv"
								then
									userlist_type_count=$(printf %s "$season_userlist_type_add" | awk -F "," '{print NF}')
									if [[ $userlist_type_count -gt 1 ]]
									then
										season_userlist_type_add=$(printf "%s,%s" "$season_userlist_type_add" "$userlist_type")
									else
										season_userlist_type_add="$userlist_type"
									fi
								fi
							done
						fi
						get-cour-rating-1
						get-cour-rating-2
						if [[ $ANIME_AWARDS == "Yes" ]]
						then
							get-animes-award
						fi
						if [[ $SEASON_YEAR == "Yes" ]]
						then
							get-animes-season-year
							if [[ $cours_count -gt 1 ]]
							then
								all_cours_anime_season=$(printf "%s,%s" "$anime_season" "$all_cours_anime_season")
							else
								all_cours_anime_season=$anime_season
							fi
						fi
					else
						printf "%s\t\t - Missing Anilist ID for tvdb : %s - Season : %s cour : %s / %s\n" "$(date +%H:%M:%S)" "$tvdb_id" "$season_number" "$cours_count" "$plex_title" | tee -a "$LOG"
						printf "%s\t\t - Missing Anilist ID for tvdb : %s - Season : %s cour : %s / %s\n" "$(date +%H:%M:%S)" "$tvdb_id" "$season_number" "$cours_count" "$plex_title" >> "$MATCH_LOG"
						((score_1_no_rating_cours++))
						((score_2_no_rating_cours++))
					fi
					total-cour-rating-1
					total-cour-rating-2
				done
				anime_season=$all_cours_anime_season
				if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
				then
					if [[ "$total_1_cours_score" != 0 ]]
					then
						total_1_cours=$((cours_count - score_1_no_rating_cours))
						if [[ "$total_1_cours" != 0 ]]
						then
							score_1_season=$(echo | awk -v v1="$total_1_cours_score" -v v2="$total_1_cours" '{print v1 / v2}')
							score_1_season=$(printf '%.*f\n' 1 "$score_1_season")
						else
							score_1_season=0
							((score_1_no_rating_seasons++))
						fi
					else
						score_1_season=0
						((score_1_no_rating_seasons++))
					fi
				fi
				if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
				then
					if [[ "$total_2_cours_score" != 0 ]]
					then
						total_2_cours=$((cours_count - score_2_no_rating_cours))
						if [[ "$total_2_cours" != 0 ]]
						then
							score_2_season=$(echo | awk -v v1="$total_2_cours_score" -v v2="$total_2_cours" '{print v1 / v2}')
							score_2_season=$(printf '%.*f\n' 1 "$score_2_season")
						else
							score_2_season=0
							((score_2_no_rating_seasons++))
						fi
					else
						score_2_season=0
						((score_2_no_rating_seasons++))
					fi
				fi
				cours_count_total=0
				anilist_id=$(jq --arg tvdb_id "$tvdb_id" --arg season_number "$season_number" '.[] | select( .tvdb_id == $tvdb_id ) | select( .tvdb_season == $season_number ) | select( .tvdb_epoffset == "0" ) | .anilist_id' -r "$ANIMEMAP_ANIMES_ID" | head -n 1)
				if [ -n "$override_id" ] && [[ $season_number -eq 1 ]]
				then
					anilist_id=$anilist_backup_id 
				fi
				if [[ -z "$anilist_id" ]]
				then
					printf "%s\t\t - Missing Anilist ID for tvdb : %s - Season : %s / %s\n" "$(date +%H:%M:%S)" "$tvdb_id" "$season_number" "$plex_title" | tee -a "$LOG"
					printf "%s - Missing Anilist ID for tvdb : %s - Season : %s / %s\n" "$(date +%H:%M:%S)" "$tvdb_id" "$season_number" "$plex_title" >> "$MATCH_LOG"
					((score_1_no_rating_seasons++))
					((score_2_no_rating_seasons++))
				else
					printf "      %s:\n" "$season_number"  >> "$METADATA"
					romaji_title=$(get-romaji-title)
					english_title=$(get-english-title)
					if [ "$english_title" == "null" ]
					then
						english_title=$romaji_title
					fi
					if [[ $ALLOW_RENAMING == "Yes" && $RENAME_SEASONS == "Yes" ]]
					then
						if [[ $MAIN_TITLE_ENG == "Yes" ]]
						then
						printf "        title: |-\n          %s\n" "$english_title" >> "$METADATA"
						else
						printf "        title: |-\n          %s\n" "$romaji_title" >> "$METADATA"
						fi
					fi
					season_label_add=""
					season_label_remove=""
					if [[ -n "$cr_awards" ]]
					then
						if [[ -n "$season_label_add" ]]
						then
							season_label_add=$(printf "%s,AA Winner" "$season_label_add")
						else
							season_label_add="AA Winner"
						fi
					fi
					if { [[ $ANILIST_LISTS_LEVEL == "season" ]] || [[ $ANILIST_LISTS_LEVEL == "both" ]]; } && [[ $ANILIST_LISTS == "Yes" ]]
					then
						seasons_userlist_type_remove="Completed,Watching,Dropped,Paused,Planning"
						userlist_type_count=$(printf %s "$season_userlist_type_add" | awk -F "," '{print NF}')
						if [[ -n $season_userlist_type_add ]] && [[ $userlist_type_count -gt 0 ]]
						then
							IFS=","
							for userlist_type in $season_userlist_type_add
							do
								seasons_userlist_type_remove=$(printf "%s" "$seasons_userlist_type_remove" | sed s/"$userlist_type"// | sed 's/^,//' | sed 's/,,/,/g')
							done
						fi
						if [[ -n "$season_userlist_type_add" ]]
						then
							if [[ -n "$season_label_add" ]]
							then
								season_label_add=$(printf "%s,%s" "$season_label_add" "$season_userlist_type_add")
							else
								season_label_add="$season_userlist_type_add"
							fi
						fi
						if [[ -n "$seasons_userlist_type_remove" ]]
						then
							if [[ -n "$season_label_remove" ]]
							then
								season_label_remove=$(printf "%s,%s" "$season_label_remove" "$seasons_userlist_type_remove")
							else
								season_label_remove="$seasons_userlist_type_remove"
							fi
						fi
					fi
					if [[ -n "$anime_season" ]]
					then
						if [[ -n "$season_label_add" ]]
						then
							season_label_add=$(printf "%s,%s" "$season_label_add" "$anime_season")
						else
							season_label_add="$anime_season"
						fi
					fi
					if [[ -n "$season_label_add" ]]
					then
						if [[ $last_season -eq 1 ]]
						then
							if [[ $IGNORE_S1_ONLY_RATING == "Yes" ]] || [[ $IGNORE_SEASONS_RATING == "Yes" ]]
							then
								printf "        label: %s\n" "$season_label_add" >> "$METADATA"
							else
								printf "        label: Score,%s\n" "$season_label_add" >> "$METADATA"
							fi
						elif [[ $IGNORE_SEASONS_RATING == "Yes" ]]
						then	
							printf "        label: %s\n" "$season_label_add" >> "$METADATA"
						else
							printf "        label: Score,%s\n" "$season_label_add" >> "$METADATA"
						fi
					else
						if [[ $last_season -eq 1 ]]
						then
							if [[ $IGNORE_S1_ONLY_RATING != "Yes" ]] || [[ $IGNORE_SEASONS_RATING != "Yes" ]]
							then
								printf "        label: Score\n" >> "$METADATA"
							fi
						elif [[ $IGNORE_SEASONS_RATING != "Yes" ]]
						then	
							printf "        label: Score\n" >> "$METADATA"
						fi
					fi
					if [[ -n "$season_label_remove" ]]
					then
						if [[ $last_season -eq 1 ]]
						then
							if [[ $IGNORE_S1_ONLY_RATING == "Yes" ]] || [[ $IGNORE_SEASONS_RATING == "Yes" ]]
							then
								printf "        label.remove: Score,%s\n" "$season_label_remove" >> "$METADATA"
							else
								printf "        label.remove: %s\n" "$season_label_remove" >> "$METADATA"
							fi
						elif [[ $IGNORE_SEASONS_RATING == "Yes" ]]
						then
							printf "        label.remove: Score,%s\n" "$season_label_remove" >> "$METADATA"
						else
							printf "        label.remove: %s\n" "$season_label_remove" >> "$METADATA"
						fi
					else
						if [[ $last_season -eq 1 ]]
						then
							if [[ $IGNORE_S1_ONLY_RATING == "Yes" ]] || [[ $IGNORE_SEASONS_RATING == "Yes" ]]
							then
							printf "        label.remove: Score\n" >> "$METADATA"
							fi
						elif [[ $IGNORE_SEASONS_RATING == "Yes" ]]
						then
							printf "        label.remove: Score\n" >> "$METADATA"
						fi
					fi
					if [[ $IGNORE_SEASONS_RATING != "Yes" ]]
					then
						if [[ $last_season -eq 1 ]]
						then
							if [[ $IGNORE_S1_ONLY_RATING != "Yes" ]]
							then
							printf "        user_rating: %s\n" "$score_1_season" >> "$METADATA"
							fi
						else
							printf "        user_rating: %s\n" "$score_1_season" >> "$METADATA"
						fi
					fi
					total-rating-1
					total-rating-2
					get-season-poster
				fi
			fi
		done
		season_loop=0
		if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
		then
			if [[ "$total_1_score" != 0 ]]
			then
				total_1_seasons=$((total_seasons - score_1_no_rating_seasons))
				if [[ "$total_1_seasons" != 0 ]]
				then
					score_1=$(echo | awk -v v1="$total_1_score" -v v2="$total_1_seasons" '{print v1 / v2}')
					score_1=$(printf '%.*f\n' 1 "$score_1")
				else
					score_1=0
				fi
			else
				score_1=0
			fi
		fi
		if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
		then
			if [[ "$total_2_score" != 0 ]]
			then
				total_2_seasons=$((total_seasons - score_2_no_rating_seasons))
				if [[ "$total_2_seasons" != 0 ]]
				then
					score_2=$(echo | awk -v v1="$total_2_score" -v v2="$total_2_seasons" '{print v1 / v2}')
					score_2=$(printf '%.*f\n' 1 "$score_2")
				else
					score_2=0
				fi
			else
				score_2=0
			fi
		fi
	else
		if [[ $RATING_1_SOURCE == "ANILIST" || $RATING_1_SOURCE == "MAL" ]]
		then
			if [[ $RATING_1_SOURCE == "ANILIST" ]]
			then
				get-score
				score_1=$anime_score
			else
				get-mal-score
				score_1=$anime_score
			fi
		fi
		if [[ "$score_1" != 0 ]]
		then
			score_1=$(printf '%.*f\n' 1 "$score_1")
		fi
		if [[ $RATING_2_SOURCE == "ANILIST" || $RATING_2_SOURCE == "MAL" ]]
		then
			if [[ $RATING_2_SOURCE == "ANILIST" ]]
			then
				get-score
				score_2=$anime_score
			else
				get-mal-score
				score_2=$anime_score
			fi
		fi
		if [[ "$score_2" != 0 ]]
		then
			score_2=$(printf '%.*f\n' 1 "$score_2")
		fi
	fi
	anilist_id=$anilist_backup_id
}
function write-metadata () {
	get-animemap-infos
	if [[ $media_type == "animes" ]]
	then
		printf "  %s:\n" "$tvdb_id" >> "$METADATA"
	else
		printf "  %s:\n" "$imdb_id" >> "$METADATA"
	fi
	romaji_title=$(get-romaji-title)
	english_title=$(get-english-title)
	native_title=$(get-native-title)
	if [ "$english_title" == "null" ]
	then
		english_title=$romaji_title
	fi
	if [ "$native_title" == "null" ]
	then
		native_title=$romaji_title
	fi
	if [[ $ALLOW_RENAMING == "Yes" ]]
	then
		if [[ $MAIN_TITLE_ENG == "Yes" ]]
		then
			if [[ $ORIGINAL_TITLE_NATIVE == "Yes" ]]
			then
				printf "    title: |-\n      %s\n    sort_title: |-\n      %s\n    original_title: |-\n      %s\n" "$english_title" "$english_title" "$native_title" >> "$METADATA"
			else
				printf "    title: |-\n      %s\n    sort_title: |-\n      %s\n    original_title: |-\n      %s\n" "$english_title" "$english_title" "$romaji_title" >> "$METADATA"
			fi
		else
			printf "    title: |-\n      %s\n" "$romaji_title" >> "$METADATA"
			if [[ $SORT_TITLE_ENG == "Yes" ]]
			then
				printf "    sort_title: |-\n      %s\n" "$english_title" >> "$METADATA"
			else
				printf "    sort_title: |-\n      %s\n" "$romaji_title" >> "$METADATA"
			fi
			if [[ $ORIGINAL_TITLE_NATIVE == "Yes" ]]
			then
				printf "    original_title: |-\n      %s\n" "$native_title" >> "$METADATA"
			else
				printf "    original_title: |-\n      %s\n" "$english_title" >> "$METADATA"
			fi
		fi
	fi
	if [[ $DISABLE_TAGS != "Yes" ]]
	then
		if [[ "$TAG_SOURCE" == "MAL" ]]
		then
			get-mal-tags
		else
			get-animemap-tags
		fi
		if [[ "$ADD_ANIME_TAG" == "No" ]]
		then
			printf "    genre.sync: %s\n" "$anime_tags" >> "$METADATA"
		else
			printf "    genre.sync: Anime,%s\n" "$anime_tags" >> "$METADATA"
		fi
	fi
	get-studios
	if [[ -n "$studio" ]]
	then
		printf "    studio: %s\n" "$studio" >> "$METADATA"
	fi
	get-poster
	if [[ $media_type == "animes" ]]
	then
		if [[ $IGNORE_SEASONS == "Yes" ]] || [[ $override_seasons_ignore == "yes" ]]
		then
			get-rating-1
			get-rating-2
		else
			get-season-infos
			check-rating-1-valid
			check-rating-2-valid
		fi
	else
		get-rating-1
		get-rating-2
	fi
	label_add=""
	label_remove=""
	if [[ $media_type == "animes" ]]
	then
		printf "%s\t\t - Writing airing status\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		if awk -F"\t" '{print "\""$1"\":"}' "$SCRIPT_FOLDER/config/data/ongoing.tsv" | grep -q -w "$tvdb_id"
		then
			label_add="Airing"
			label_remove="Planned,Ended"
			printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
		else
			get-airing-status
			if [[ $airing_status == Planned ]]
			then
				label_add="Planned"
				label_remove="Airing,Ended"
				printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
			else
				label_add="Ended"
				label_remove="Planned,Airing"
				printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
			fi
		fi
	fi
	if [[ -n $cr_awards ]]
	then
		if [[ -n "$label_add" ]]
		then
			label_add=$(printf "AA Winner,%s" "$label_add")
		else
			label_add="AA Winner"
		fi
	else
		get-animes-award
		if [[ -n $cr_awards ]]
		then
			if [[ -n "$label_add" ]]
			then
				label_add=$(printf "AA Winner,%s" "$label_add")
			else
				label_add="AA Winner"
			fi
		fi
	fi
	if { [[ $ANILIST_LISTS_LEVEL == "show" ]] || [[ $ANILIST_LISTS_LEVEL == "both" ]]; } && [[ $ANILIST_LISTS == "Yes" ]]
	then
		all_anilist_ids=""
		userlist_type_add=""
		userlist_type_remove="Completed,Watching,Dropped,Paused,Planning"
		for userlist_type in Completed Watching Dropped Paused Planning
		do
			if [[ $media_type == "animes" ]]
			then
				all_anilist_ids=$(jq --arg tvdb_id "$tvdb_id" '.[] | select( .tvdb_id == $tvdb_id ) | .anilist_id' -r "$ANIMEMAP_ANIMES_ID" | paste -s -d, - | sed 's/,/\\|/g')
			else
				all_anilist_ids=$anilist_id
			fi
			if grep -q -w "$all_anilist_ids" "$SCRIPT_FOLDER/config/data/anilist-$ANILIST_USERNAME-$userlist_type.tsv"
			then
				userlist_type_count=$(printf %s "$userlist_type_add" | awk -F "," '{print NF}')
				if [[ $userlist_type_count -gt 1 ]]
				then
					userlist_type_add=$(printf "%s,%s" "$userlist_type_add" "$userlist_type")
				else
					userlist_type_add=$userlist_type
				fi
				userlist_type_remove=$(printf "%s" "$userlist_type_remove" | sed s/"$userlist_type"// | sed 's/^,//' | sed 's/,,/,/g')
			fi
		done
		if [[ -n "$userlist_type_add" ]]
		then
			if [[ -n "$label_add" ]]
			then
				label_add=$(printf "%s,%s" "$label_add" "$userlist_type_add")
			else
				label_add="$userlist_type_add"
			fi
		fi
		if [[ -n "$userlist_type_remove" ]]
		then
			if [[ -n "$label_remove" ]]
			then
				label_remove=$(printf "%s,%s" "$label_remove" "$userlist_type_remove")
			else
				label_remove="$userlist_type_remove"
			fi
		fi
	fi
	if [[ -n "$label_add" ]]
	then
		printf "    label: %s\n" "$label_add" >> "$METADATA"
	fi
	if [[ -n "$label_remove" ]]
	then
		printf "    label.remove: %s\n" "$label_remove" >> "$METADATA"
	fi
	tvdb_id=""
	imdb_id=""
	anilist_id=""
	mal_id=""
	override_seasons_ignore=""
	award_check=""
	cr_awards=""
}
