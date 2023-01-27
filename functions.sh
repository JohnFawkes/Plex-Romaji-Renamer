#!/bin/bash

# functions
function get-mal-id-from-tvdb-id () {
jq ".[] | select( .tvdb_id == ${tvdb_id} ) | select( .tvdb_season == 1 ) | select( .tvdb_epoffset == 0 ) | .mal_id" -r $SCRIPT_FOLDER/tmp/list-animes-id.json
}
function get-mal-id-from-imdb-id () {
imdb_jq=$(echo $imdb_id | awk '{print "\""$1"\""}' )
jq ".[] | select( .imdb_id == ${imdb_jq} )" -r $SCRIPT_FOLDER/tmp/list-animes-id.json | jq .mal_id | sort -n | head -1
}
function get-anilist-id () {
jq ".[] | select( .mal_id == ${mal_id} ) | .anilist_id" -r $SCRIPT_FOLDER/tmp/list-animes-id.json
}
function get-tvdb-id () {
jq ".[] | select( .mal_id == ${mal_id} ) | .tvdb_id" -r $SCRIPT_FOLDER/tmp/list-animes-id.json
}
function get-mal-infos () {
if [ ! -f $SCRIPT_FOLDER/data/$mal_id.json ] 										#check if exist
then
	sleep 0.5
	curl "https://api.jikan.moe/v4/anime/$mal_id" > $SCRIPT_FOLDER/data/$mal_id.json
	sleep 1.5
fi
}
function get-anilist-infos () {
if [ ! -f $SCRIPT_FOLDER/data/title-$mal_id.json ]
then
	sleep 0.5
	curl 'https://graphql.anilist.co/' \
	-X POST \
	-H 'content-type: application/json' \
	--data '{ "query": "{ Media(id: '"$anilist_id"') { title { romaji } } }" }' > $SCRIPT_FOLDER/data/title-$mal_id.json
	sleep 1.5
fi
}
function get-anilist-title () {
jq .data.Media.title.romaji -r $SCRIPT_FOLDER/data/title-$mal_id.json
}
function get-mal-eng-title () {
jq .data.title_english -r $SCRIPT_FOLDER/data/$mal_id.json
}
function get-mal-rating () {
jq .data.score -r $SCRIPT_FOLDER/data/$mal_id.json
}
function get-mal-poster () {
if [ ! -f $POSTERS_FOLDER/$mal_id.jpg ]										#check if exist
then
	sleep 0.5
	mal_poster_url=$(jq .data.images.jpg.large_image_url -r $SCRIPT_FOLDER/data/$mal_id.json)
	wget --no-use-server-timestamps -O $POSTERS_FOLDER/$mal_id.jpg "$mal_poster_url"
	sleep 1.5
else
	postersize=$(du -b $POSTERS_FOLDER/$mal_id.jpg | awk '{ print $1 }')
	if [[ $postersize -lt 10000 ]]
	then
		rm $POSTERS_FOLDER/$mal_id.jpg
		sleep 0.5
		mal_poster_url=$(jq .data.images.jpg.large_image_url -r $SCRIPT_FOLDER/data/$mal_id.json)
		wget --no-use-server-timestamps -O $POSTERS_FOLDER/$mal_id.jpg "$mal_poster_url"
		sleep 1.5
	fi
fi
}
function get-mal-tags () {
(jq '.data.genres  | .[] | .name' -r $SCRIPT_FOLDER/data/$mal_id.json && jq '.data.demographics  | .[] | .name' -r $SCRIPT_FOLDER/data/$mal_id.json && jq '.data.themes  | .[] | .name' -r $SCRIPT_FOLDER/data/$mal_id.json) | awk '{print $0}' | paste -s -d, -
}
function get-mal-studios() {
if awk -F"\t" '{print $2}' $SCRIPT_FOLDER/$OVERRIDE | grep -w  $mal_id
then
     line=$(grep -w -n $mal_id $SCRIPT_FOLDER/$OVERRIDE | cut -d : -f 1)
	studio=$(sed -n "${line}p" $SCRIPT_FOLDER/$OVERRIDE | awk -F"\t" '{print $4}')
     if [[ -z "$studio" ]]
	then
          mal_studios=$(jq '.data.studios[0] | [.name]| @tsv' -r $SCRIPT_FOLDER/data/$mal_id.json)
     else
          mal_studios=$(echo "$studio")
     fi
else
	mal_studios=$(jq '.data.studios[0] | [.name]| @tsv' -r $SCRIPT_FOLDER/data/$mal_id.json)
fi
}
function downlaod-anime-id-mapping () {
wait_time=0
while [ $wait_time -lt 4 ];
do
	wget -O $SCRIPT_FOLDER/tmp/list-animes-id.json "https://raw.githubusercontent.com/Arial-Z/Animes-ID/main/list-animes-id.json"
	size=$(du -b $SCRIPT_FOLDER/tmp/list-animes-id.json | awk '{ print $1 }')
		((wait_time++))
	if [[ $size -gt 1000 ]]
	then
		break
	fi
	if [[ $wait_time == 4 ]]
	then
		echo "$(date +%Y.%m.%d" - "%H:%M:%S) - error can't download anime ID mapping file, exiting" >> $LOG
		echo "error can't download anime ID mapping file, exiting"
		exit 1
	fi
	sleep 30
done
}
function write-metadata () {
get-mal-infos
echo "  \"$title_anime\":" >> $METADATA
if [[ $title_anime != $title_plex ]]
then
	echo "    alt_title: \"$title_plex\"" >> $METADATA
fi
echo "    sort_title: \"$title_anime\"" >> $METADATA
title_eng=$(get-mal-eng-title)
if [ "$title_eng" == "null" ]
then
	echo "    original_title: \"$title_anime\"" >> $METADATA
else 
	echo "    original_title: \"$title_eng\"" >> $METADATA
fi
printf "$(date +%Y.%m.%d" - "%H:%M:%S) - $title_anime:\n" >> $LOG
score_mal=$(get-mal-rating)
echo "    critic_rating: $score_mal" >> $METADATA									# rating (critic)
printf "$(date +%Y.%m.%d" - "%H:%M:%S)\t\tscore : $score_mal\n" >> $LOG
mal_tags=$(get-mal-tags)
echo "    genre.sync: Anime,${mal_tags}"  >> $METADATA									# tags (genres, themes and demographics from MAL)
printf "$(date +%Y.%m.%d" - "%H:%M:%S)\t\ttags : $mal_tags\n" >> $LOG
if [[ $OVERRIDE == override-ID-animes.tsv ]]
then
	if awk -F"\t" '{print "\""$1"\":"}' $SCRIPT_FOLDER/data/ongoing.tsv | grep -w "$mal_id"		# Ongoing label according to MAL airing list
	then
		echo "    label: Ongoing" >> $METADATA
		printf "$(date +%Y.%m.%d" - "%H:%M:%S)\t\tLabel add Ongoing\n" >> $LOG
	else
		echo "    label.remove: Ongoing" >> $METADATA
		printf "$(date +%Y.%m.%d" - "%H:%M:%S)\t\tLabel remove Ongoing\n" >> $LOG
	fi
fi
get-mal-studios
echo "    studio: ${mal_studios}"  >> $METADATA
printf "$(date +%Y.%m.%d" - "%H:%M:%S)\t\tstudio : $mal_studios\n" >> $LOG
get-mal-poster																# check / download poster
if [ "$PMM_INSTALL_TYPE"  == "docker" ]
then
	echo "    file_poster: $POSTERS_PMM_FOLDER/${mal_id}.jpg" >> $METADATA
	printf "$(date +%Y.%m.%d" - "%H:%M:%S)\t\tPoster added\n" >> $LOG
else
	echo "    file_poster: $POSTERS_FOLDER/${mal_id}.jpg" >> $METADATA
	printf "$(date +%Y.%m.%d" - "%H:%M:%S)\t\tPoster added\n" >> $LOG
fi
}