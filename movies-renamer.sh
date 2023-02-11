#!/bin/bash

SCRIPT_FOLDER=$(dirname $(readlink -f $0))
media_type=movies
source $SCRIPT_FOLDER/config.conf
source $SCRIPT_FOLDER/functions.sh
METADATA=$METADATA_MOVIES
OVERRIDE=override-ID-$media_type.tsv

#check temp folder + run of pmm for ID
pmm-id-run

# check if files and folder exist
echo "metadata:" > $METADATA
if [ ! -d $SCRIPT_FOLDER/data ]											#check if exist and create folder for json data
then
	mkdir $SCRIPT_FOLDER/data
else
	find $SCRIPT_FOLDER/data/* -mmin +2880 -exec rm {} \;				#delete json data if older than 2 days
fi
if [ ! -d $POSTERS_FOLDER ]
then
	mkdir $POSTERS_FOLDER
else
	find $POSTERS_FOLDER/* -mtime +30 -exec rm {} \;
fi
if [ ! -d $SCRIPT_FOLDER/ID ]
then
	mkdir $SCRIPT_FOLDER/ID
	touch $SCRIPT_FOLDER/ID/movies.tsv
elif [ ! -f $SCRIPT_FOLDER/ID/movies.tsv ]
then
	touch $SCRIPT_FOLDER/ID/movies.tsv
else
	rm $SCRIPT_FOLDER/ID/movies.tsv
	touch $SCRIPT_FOLDER/ID/movies.tsv
fi
if [ ! -d $LOG_FOLDER ]
then
	mkdir $LOG_FOLDER
fi

# Download anime mapping json data
download-anime-id-mapping


# create clean list-movies.tsv (imdb_id | title_plex) from meta.log
line_start=$(grep -n "Mapping $MOVIE_LIBRARY_NAME Library" $SCRIPT_FOLDER/tmp/meta.log | cut -d : -f 1)
line_end=$(grep -n -m1 "$MOVIE_LIBRARY_NAME Library Operations" $SCRIPT_FOLDER/tmp/meta.log | cut -d : -f 1)
head -n $line_end $SCRIPT_FOLDER/tmp/meta.log | tail -n $(( $line_end - $line_start - 1 )) | head -n -5 > $SCRIPT_FOLDER/tmp/cleanlog-movies.txt
awk -F"|" '{ OFS = "\t" } ; { gsub(/ /,"",$6) } ; { print  substr($6,8),substr($7,2,length($7)-2) }' $SCRIPT_FOLDER/tmp/cleanlog-movies.txt > $SCRIPT_FOLDER/tmp/list-movies.tsv

# create ID/movies.tsv ( imdb_id | mal_id | title_anime | title_plex )
while IFS=$'\t' read -r imdb_id mal_id title_anime studio
do
	if ! awk -F"\t" '{print $1}' $SCRIPT_FOLDER/ID/movies.tsv | grep -w  $imdb_id
	then
		if awk -F"\t" '{print $1}' $SCRIPT_FOLDER/tmp/list-movies.tsv | grep -w  $imdb_id
		then
			line=$(grep -w -n $imdb_id $SCRIPT_FOLDER/tmp/list-movies.tsv | cut -d : -f 1)
			title_plex=$(sed -n "${line}p" $SCRIPT_FOLDER/tmp/list-movies.tsv | awk -F"\t" '{print $2}')
			printf "$imdb_id\t$mal_id\t$title_anime\t$title_plex\n" >> $SCRIPT_FOLDER/ID/movies.tsv
			echo "$(date +%Y.%m.%d" - "%H:%M:%S) - override found for : $title_anime / $title_plex" >> $LOG
		fi
	fi
done < $SCRIPT_FOLDER/override-ID-movies.tsv
while IFS=$'\t' read -r imdb_id title_plex											# then get the other ID from the ID mapping and download json data
do
	if ! awk -F"\t" '{print $1}' $SCRIPT_FOLDER/ID/movies.tsv | grep -w  $imdb_id
	then
		mal_id=$(get-mal-id-from-imdb-id)
		if [[ "$mal_id" == 'null' ]] || [[ "${#mal_id}" == '0' ]]						# Ignore anime with no tvdb to mal id conversion show in the error log you need to add them by hand in override
		then
			echo "$(date +%Y.%m.%d" - "%H:%M:%S) - invalid MAL ID for : imdb : $imdb_id / $title_plex" >> $MATCH_LOG
			continue
		fi
		anilist_id=$(get-anilist-id)
		if [[ "$anilist_id" == 'null' ]] || [[ "${#anilist_id}" == '0' ]]				# Ignore anime with no tvdb to mal id conversion show in the error log you need to add them by hand in override
		then
			echo "$(date +%Y.%m.%d" - "%H:%M:%S) - invalid Anilist ID for : imdb : $imdb_id / $title_plex" >> $MATCH_LOG
			continue
		fi
		get-mal-infos
		get-anilist-infos
		title_anime=$(get-anilist-title)
		printf "$imdb_id\t$mal_id\t$title_anime\t$title_plex\n" >> $SCRIPT_FOLDER/ID/movies.tsv
		echo "$(date +%Y.%m.%d" - "%H:%M:%S) - $title_anime / $title_plex added to ID/movies.tsv" >> $LOG
	fi
done < $SCRIPT_FOLDER/tmp/list-movies.tsv

# write PMM metadata file from ID/movies.tsv and jikan API
while IFS=$'\t' read -r imdb_id mal_id title_anime title_plex
do
	write-metadata
done < $SCRIPT_FOLDER/ID/movies.tsv
exit 0