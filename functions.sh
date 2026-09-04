#!/bin/bash

#General variables
LOG=$LOG_FOLDER/RR_$(date +%Y.%m.%d).log
MATCH_LOG=$LOG_FOLDER/${media_type}-missing-id.log

#AnimeMap API (https://animemap.dev/docs)
ANIMEMAP_API_URL=${ANIMEMAP_API_URL:-https://mapping.animemap.dev/api/v1}
ANIMEMAP_API_KEY=${ANIMEMAP_API_KEY:-}
ANIMEMAP_API_RETRY=${ANIMEMAP_API_RETRY:-4}
ANILIST_TAGS_P=${ANILIST_TAGS_P:-70}

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
		http_code=$(curl -s --max-time 300 --compressed "${api_key_header[@]}" -o "$output" -w "%{http_code}" "$url")
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
function get-animemap-tvdb-lookup () {													# every entry carrying $tvdb_id, cached, sets $tvdb_map_file
	tvdb_map_file="$SCRIPT_FOLDER/config/data/animemap-tvdb-$tvdb_id.json"
	# a cache written before the format and offset keys existed cannot answer the season 0 fallback, so it is downloaded again
	if [ -f "$tvdb_map_file" ] && jq -e 'length == 0 or ( .[0] | has( "tvdb_epoffset_null" ) )' "$tvdb_map_file" > /dev/null 2>&1
	then
		return 0
	fi
	local api_file="$SCRIPT_FOLDER/config/tmp/animemap-lookup.json"
	printf "%s\t\t - Downloading the entries of tvdb : %s\n" "$(date +%H:%M:%S)" "$tvdb_id" | tee -a "$LOG" >&2
	if ! animemap-api-get "$ANIMEMAP_API_URL/mapping/lookup/tvdb/$tvdb_id" "$api_file"
	then
		printf "%s - Error can't read the entries of tvdb : %s stopping script\n" "$(date +%H:%M:%S)" "$tvdb_id" | tee -a "$LOG" >&2
		exit 1
	fi
	# a tvdb season of "a" (absolute numbering) or none at all is kept as "-1", the value the season logic uses for "not split per tvdb season"
	jq -c --arg tvdb_id "$tvdb_id" '[ .entries[]
		| select( .anilist_id != null )
		| { tvdb_id: $tvdb_id,
			tvdb_season: ( if ( .tvdb.season | type ) == "number" then ( .tvdb.season | tostring ) else "-1" end ),
			tvdb_epoffset: ( ( .tvdb.episode_offset // 0 ) | tostring ),
			tvdb_epoffset_null: ( .tvdb.episode_offset == null ),
			format: ( ( .format // "" ) | tostring ),
			anidb_id: ( ( .anidb.id // "" ) | tostring ),
			mal_id: ( ( .mal.id // "" ) | tostring ),
			anilist_id: ( .anilist_id | tostring ) } ]' "$api_file" > "$tvdb_map_file"
	rm -f "$api_file"
	printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG" >&2
}
function get-animemap-imdb-lookup () {													# every entry carrying $imdb_id, cached, sets $imdb_map_file
	imdb_map_file="$SCRIPT_FOLDER/config/data/animemap-imdb-$imdb_id.json"
	if [ -f "$imdb_map_file" ]
	then
		return 0
	fi
	local api_file="$SCRIPT_FOLDER/config/tmp/animemap-lookup.json"
	printf "%s\t\t - Downloading the entries of imdb : %s\n" "$(date +%H:%M:%S)" "$imdb_id" | tee -a "$LOG" >&2
	if ! animemap-api-get "$ANIMEMAP_API_URL/mapping/lookup/imdb/$imdb_id" "$api_file"
	then
		printf "%s - Error can't read the entries of imdb : %s stopping script\n" "$(date +%H:%M:%S)" "$imdb_id" | tee -a "$LOG" >&2
		exit 1
	fi
	# only what a plex movies library can hold, so a serie imdb id never matches a movie
	jq -c --arg imdb_id "$imdb_id" '[ .entries[]
		| select( .anilist_id != null )
		| select( .format == "MOVIE" or .tmdb.media_type == "movie" )
		| { imdb_id: $imdb_id,
			anidb_id: ( ( .anidb.id // "" ) | tostring ),
			mal_id: ( ( .mal.id // "" ) | tostring ),
			anilist_id: ( .anilist_id | tostring ) } ]' "$api_file" > "$imdb_map_file"
	rm -f "$api_file"
	printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG" >&2
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
		get-animemap-tvdb-lookup
		# AnimeMap files plenty of first seasons at tvdb season 0, so the season 1 entry the old mapping always carried is often not there.
		# when no entry answers the season 1 filter, fall back to the oldest serie entry, a TV before a TV_SHORT before an ONA,
		# then to the oldest entry of any format, the API listing them oldest season first with the undated ones last
		jq -r '[ .[] | select( ( .tvdb_season == "1" or .tvdb_season == "-1" ) and .tvdb_epoffset == "0" ) ] as $season_one
			| ( [ .[] | select( .format == "TV" or .format == "TV_SHORT" or .format == "ONA" ) ]
				| to_entries
				| sort_by( [ ( if .value.format == "TV" then 0 elif .value.format == "TV_SHORT" then 1 else 2 end ), .key ] )
				| map( .value ) ) as $series
			| ( if ( $season_one | length ) > 0 then $season_one elif ( $series | length ) > 0 then $series else . end )
			| .[0].anilist_id // empty' "$tvdb_map_file"
	else
		get-animemap-imdb-lookup
		jq '.[0].anilist_id // empty' -r "$imdb_map_file"
	fi
}
function get-mal-id () {
	get-animemap-infos
	mal_id=$(jq '.mal_id' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
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
		tvdb_id: null,
		tvdb_season: null,
		tvdb_epoffset: null,
		crunchyroll_awards: [] }'
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
	if [[ $cours_count_total -gt 1 ]]
	then
		printf "%s\t\t - Downloading data for S%s part-%s animemap : %s\n" "$(date +%H:%M:%S)" "$season_number" "$cours_count" "$anilist_id" | tee -a "$LOG" >&2
	elif [[ "$season_loop" == 1 ]]
	then
		printf "%s\t\t - Downloading data for S%s animemap : %s\n" "$(date +%H:%M:%S)" "$season_number" "$anilist_id" | tee -a "$LOG" >&2
	else
		printf "%s\t\t - Downloading data for animemap : %s\n" "$(date +%H:%M:%S)" "$anilist_id" | tee -a "$LOG" >&2
	fi
	animemap-api-get "$ANIMEMAP_API_URL/mapping/anilist/$anilist_id?include_spoilers=true" "$api_file"
	api_status=$?
	if [[ $api_status == 1 ]]
	then
		printf "%s - Error can't download animemap data stopping script\n" "$(date +%H:%M:%S)" | tee -a "$LOG" >&2
		exit 1
	fi
	if [[ $api_status == 2 ]]
	then																				# nothing carries that id, keep an empty record so the run carries on
		printf "%s\t\t - Unknown Anilist id on AnimeMap : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" | tee -a "$LOG" >&2
		printf "%s - Unknown Anilist id on AnimeMap : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" >> "$MATCH_LOG"
		animemap-empty-record "$anilist_id" > "$data_file"
		return 0
	fi
	# a studio name comes back as an object here and as a string elsewhere, so both are reduced to the name
	jq -c '.mapping | { anilist_id: .anilist.anilist_id,
		title_romaji: .anilist.title_romaji,
		title_english: .anilist.title_english,
		title_native: .anilist.title_native,
		format: .anilist.format,
		episodes: .anilist.episodes,
		season_year: .anilist.season_year,
		season: .anilist.season,
		status: .anilist.status,
		average_score: .anilist.average_score,
		genres: ( .anilist.genres // [] ),
		tags: [ .anilist.tags[]? | { name, rank } ],
		studios: [ .anilist.studios[]? | if type == "object" then .name else . end ],
		cover_image: .anilist.cover_image,
		mal_id: .mal.id,
		tvdb_id: .tvdb.id,
		tvdb_season: ( if ( .tvdb.season | type ) == "number" then ( .tvdb.season | tostring ) else "-1" end ),
		tvdb_epoffset: ( ( .tvdb.episode_offset // 0 ) | tostring ),
		crunchyroll_awards: ( .crunchyroll_awards // [] ) }' "$api_file" > "$data_file"
	rm -f "$api_file"
	printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG" >&2
}
function get-mal-infos () {																# the MyAnimeList data AnimeMap serves alongside a mapping, a raw jikan data object
	mal_id=""
	get-mal-id
	if [[ $mal_id == 'null' ]] || [[ -z $mal_id ]]
	then
		printf "%s\t\t - Missing MAL ID for Anilist : %s / %s\n" "$(date +%H:%M:%S)" "$anilist_id" "$plex_title" | tee -a "$LOG" >&2
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
		printf "%s\t\t - Downloading data for S%s part-%s MAL : %s\n" "$(date +%H:%M:%S)" "$season_number" "$cours_count" "$mal_id" | tee -a "$LOG" >&2
	elif [[ "$season_loop" == 1 ]]
	then
		printf "%s\t\t - Downloading data for S%s MAL : %s\n" "$(date +%H:%M:%S)" "$season_number" "$mal_id" | tee -a "$LOG" >&2
	else
		printf "%s\t\t - Downloading data for MAL : %s\n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG" >&2
	fi
	if ! animemap-api-get "$ANIMEMAP_API_URL/mapping/anilist/$anilist_id?include_spoilers=true" "$api_file"
	then
		printf "%s\t\t - Can't download MAL data for : %s skipping\n" "$(date +%H:%M:%S)" "$mal_id" | tee -a "$LOG" >&2
		return 0
	fi
	if jq -e '.mapping.mal.data == null' "$api_file" > /dev/null					# a miss is never cached, MAL is an upstream AnimeMap calls live
	then
		printf "%s\t\t - No MAL data returned for : %s / %s\n" "$(date +%H:%M:%S)" "$mal_id" "$(jq -r '( .warnings // [] ) | join(" ")' "$api_file")" | tee -a "$LOG" >&2
		printf "%s - No MAL data returned for : %s / %s\n" "$(date +%H:%M:%S)" "$mal_id" "$plex_title" >> "$MATCH_LOG"
		rm -f "$api_file"
		return 0
	fi
	jq -c '{ data: .mapping.mal.data }' "$api_file" > "$mal_file"
	rm -f "$api_file"
	printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG" >&2
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
function get-animemap-tags () {															# the anilist genres, plus the tags ranked at or above ANILIST_TAGS_P
	get-animemap-infos
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
	get-mal-infos																		# anilist does not name a studio for every entry, MAL usually does
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
	get-animemap-infos
	if [[ $ANIME_AWARDS_NO_FVA == "Yes" ]]
	then
		award_check=$(jq '.crunchyroll_awards[]? | select(.award | contains("English") or contains("Arabic") or contains("Spanish") or contains("Castilian") or contains("French")or contains("German") or contains("Italian") or contains("Portuguese") or contains("Russian")  | not) | "AA " + ( .year | tostring ) + " " + .award' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json" | paste -s -d, -)  > /dev/null
		if [[ -n $award_check ]]
		then
			cr_awards=$award_check
		fi
	else
		award_check=$(jq '.crunchyroll_awards[]? | "AA " + ( .year | tostring ) + " " + .award' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json" | paste -s -d, -)  > /dev/null
		if [[ -n $award_check ]]
		then
			cr_awards=$award_check
		fi
	fi
}
function entry-is-a-return () {															# a movie, an OVA or a one off special is not the serie coming back, a season in any serie format is
	case $(jq '.format // "null"' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json") in
		TV|TV_SHORT|ONA|null)	return 0 ;;
		*)						return 1 ;;
	esac
}
function get-announced-sequel () {														# a just announced season usually has no tvdb id yet, so the tvdb entries cannot find it
	local api_file="$SCRIPT_FOLDER/config/tmp/animemap-search.json"
	local search_file="$SCRIPT_FOLDER/config/data/animemap-search-$anilist_id.json"
	local search_title=""
	local query=""
	local candidate=""
	announced_sequel="no"
	search_title=$(jq '.title_romaji // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	if [[ -z $search_title ]]
	then
		return 0
	fi
	if [ ! -f "$search_file" ]
	then
		query=$(jq -rn --arg title "$search_title" '$title | @uri')
		printf "%s\t\t - Looking for an announced sequel of : %s\n" "$(date +%H:%M:%S)" "$search_title" | tee -a "$LOG" >&2
		if ! animemap-api-get "$ANIMEMAP_API_URL/search?q=$query&limit=25" "$api_file"
		then
			printf "%s\t\t - Can't search for : %s skipping\n" "$(date +%H:%M:%S)" "$search_title" | tee -a "$LOG" >&2
			return 0
		fi
		# nothing unreleased is dated before the current year, so this drops the back catalogue without dropping a candidate
		jq -c --argjson year "$(date +%Y)" '[ .anilist[]? | select( .mapping.season_year == null or .mapping.season_year >= $year ) | .id ]' "$api_file" > "$search_file"
		rm -f "$api_file"
	fi
	local anilist_backup_id=$anilist_id
	for candidate in $(jq '.[]' -r "$search_file")
	do
		anilist_id=$candidate
		get-animemap-infos
		if ! entry-is-a-return
		then
			continue
		fi
		case $(jq '.status // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json") in
			RELEASING)			announced_sequel="airing"; break ;;
			NOT_YET_RELEASED)	announced_sequel="planned" ;;
		esac
	done
	anilist_id=$anilist_backup_id
}
function get-airing-status () {															# AnimeMap carries no anilist relation, so the entries of the tvdb serie stand in for the sequel chain
	local IFS=$' \t\n'																		# get-season-infos splits on commas, the ids read below are one per line
	local anilist_backup_id=$anilist_id
	local sequel_ids=""
	local sequel_id=""
	local entry_status=""
	airing_status="Ended"
	get-animemap-infos
	entry_status=$(jq '.status // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
	if [[ $entry_status == "RELEASING" ]]
	then
		airing_status="Airing"
		return 0
	fi
	if [[ $entry_status == "NOT_YET_RELEASED" ]]
	then
		airing_status="Planned"
	fi
	if [[ $media_type != "animes" ]] || [[ -z $tvdb_id ]]
	then
		return 0
	fi
	get-animemap-tvdb-lookup
	sequel_ids=$(jq '.[].anilist_id' -r "$tvdb_map_file" | sort -n | uniq)
	for sequel_id in $sequel_ids
	do
		anilist_id=$sequel_id
		get-animemap-infos
		if ! entry-is-a-return
		then
			continue
		fi
		entry_status=$(jq '.status // empty' -r "$SCRIPT_FOLDER/config/data/animemap-$anilist_id.json")
		if [[ $entry_status == "RELEASING" ]]											# something of this serie on air outranks something merely announced
		then
			airing_status="Airing"
			break
		fi
		if [[ $entry_status == "NOT_YET_RELEASED" ]]
		then
			airing_status="Planned"
		fi
	done
	anilist_id=$anilist_backup_id
	if [[ $airing_status != "Ended" ]]													# only a serie that looks finished is worth the search
	then
		return 0
	fi
	get-announced-sequel
	if [[ $announced_sequel == "airing" ]]
	then
		airing_status="Airing"
	elif [[ $announced_sequel == "planned" ]]
	then
		airing_status="Planned"
	fi
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
function tvdb-season-entries () {														# the entries filed under tvdb season $1, as a json array
	# a first season AnimeMap could not place lands at tvdb season 0 carrying no episode offset, which is also where the real specials sit,
	# so only a serie entry with no offset at all is read as the season 1 the mapping is missing
	jq -c --arg season_number "$1" '[ .[] | select( .tvdb_season == $season_number ) ] as $season
		| if ( $season | length ) > 0 then $season
			elif $season_number == "1"
			then ( [ .[] | select( .tvdb_season == "0" and .tvdb_epoffset_null and ( .format == "TV" or .format == "TV_SHORT" or .format == "ONA" ) ) ]
				| to_entries
				| sort_by( [ ( if .value.format == "TV" then 0 elif .value.format == "TV_SHORT" then 1 else 2 end ), .key ] )
				| map( .value )[0:1] )
			else [] end' "$tvdb_map_file"
}
function get-season-infos () {
	override_id=""
	anilist_backup_id=$anilist_id
	get-animemap-tvdb-lookup
	season_check=$(jq --arg anilist_id "$anilist_id" '.[] | select( .anilist_id == $anilist_id ) | .tvdb_season' -r "$tvdb_map_file")
	first_season=$(echo "$seasons_list" | awk -F "," '{print $1}')
	last_season=$(echo "$seasons_list" | awk -F "," '{print $NF}')
	total_seasons=$(echo "$seasons_list" | awk -F "," '{print NF}')
	valid_anilist_id=$(jq '.[].anilist_id' -r "$tvdb_map_file")
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
				anilist_ids=$(tvdb-season-entries "$season_number" | jq -r 'sort_by(.tvdb_epoffset) | .[].anilist_id' | paste -s -d, -)
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
				anilist_id=$(tvdb-season-entries "$season_number" | jq -r '.[] | select( .tvdb_epoffset == "0" ) | .anilist_id' | head -n 1)
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
		get-airing-status
		if [[ $airing_status == Airing ]]
		then
			label_add="Airing"
			label_remove="Planned,Ended"
		elif [[ $airing_status == Planned ]]
		then
			label_add="Planned"
			label_remove="Airing,Ended"
		else
			label_add="Ended"
			label_remove="Planned,Airing"
		fi
		printf "%s\t\t - Done\n" "$(date +%H:%M:%S)" | tee -a "$LOG"
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
				get-animemap-tvdb-lookup
				all_anilist_ids=$(jq '.[].anilist_id' -r "$tvdb_map_file" | paste -s -d, - | sed 's/,/\\|/g')
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
