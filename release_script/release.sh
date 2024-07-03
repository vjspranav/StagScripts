#!/bin/bash

# Environment variables, Expected to set SSHPASS environment variable
# Expects ~/channel.conf file with telegram-send configuration

device="${device}"
path="/home/frs/project/stagos-14/${device}/"

# Get device details
json_data=$(curl -s "https://api.stag-os.org/maintainers/${device}")

# Extract data from JSON
device_name=$(echo "${json_data}" | jq -r '.data.device_name')
device_codename=$(echo "${json_data}" | jq -r '.data.device_codename')
tg_username=@$(echo "${json_data}" | jq -r '.data.tg_username')

# Get current date
date=$(date "+%d-%b-%Y")

# Telegram-send informing about the release
telegram-send "Uploading StagOS ${version} for ${device}. CC: ${tg_username}"

# File paths
filep=$(ls /var/lib/jenkins/builds/${device}/StagOS-${device}*-OFFICIAL-*Pristine*.zip)
fileg=$(ls /var/lib/jenkins/builds/${device}/StagOS-${device}*-OFFICIAL-*GApps*.zip)
incremental_filep=$(ls /var/lib/jenkins/builds/${device}/StagOS-${device}-incremental-*Pristine*.zip)
incremental_fileg=$(ls /var/lib/jenkins/builds/${device}/StagOS-${device}-incremental-*GApps*.zip)

# Filename is of format StagOS-porsche-14.3.0-OFFICIAL-GApps-20240703-1527-signed.zip
# 14.3.0 is the version number and 14 is Android version
filename=$(basename "${filep}")
version=$(echo "${filename}" | sed -E 's/.*StagOS-.*-([0-9]+\.[0-9]+\.[0-9]+)-OFFICIAL.*/\1/')
android_version=$(echo "${version}" | cut -d'.' -f1)

# File sizes
sizep=$(du -sh "${filep}" | cut -f1)
sizeg=$(du -sh "${fileg}" | cut -f1)

# MD5 hashes
md5p=$(md5sum "${filep}" | cut -d' ' -f1)
md5g=$(md5sum "${fileg}" | cut -d' ' -f1)

# Download links
linkp="https://sourceforge.net/projects/stagos-14/files/${device}/$(basename "${filep}")"
linkg="https://sourceforge.net/projects/stagos-14/files/${device}/$(basename "${fileg}")"

echo LinkP: ${linkp} LinkG: ${linkg}

# if both incremental files are present
INCREMENTAL_PRESENT=false

if [ -f "${incremental_filep}" ] && [ -f "${incremental_fileg}" ]; then
    INCREMENTAL_PRESENT=true
    link_incremental_p="https://sourceforge.net/projects/stagos-14/files/${device}/incremental/$(basename "${incremental_filep}")"
    link_incremental_g="https://sourceforge.net/projects/stagos-14/files/${device}/incremental/$(basename "${incremental_fileg}")"
fi

echo "Uploading files to SourceForge"
echo Inremental Present: ${INCREMENTAL_PRESENT}

# SFTP commands
echo "put ${filep} ${path}" | ./sshpass -e sftp -oBatchMode=no -b - stag-maintainer@frs.sourceforge.net
echo "put ${fileg} ${path}" | ./sshpass -e sftp -oBatchMode=no -b - stag-maintainer@frs.sourceforge.net

if [ "${INCREMENTAL_PRESENT}" = true ]; then
    echo "put ${incremental_filep} ${path}incremental/" | ./sshpass -e sftp -oBatchMode=no -b - stag-maintainer@frs.sourceforge.net
    echo "put ${incremental_fileg} ${path}incremental/" | ./sshpass -e sftp -oBatchMode=no -b - stag-maintainer@frs.sourceforge.net
fi

# Copy target folders
# delete existing files
rm -rf /var/lib/jenkins/target_files/${device}/rel/*
# copy new folders
cp -r /var/lib/jenkins/target_files/${device}/cur/* /var/lib/jenkins/target_files/${device}/rel/

# Create message
read -r -d '' msg <<EOT
<b>StagOS ${version} | Android ${android_version}</b>
<b>New build available for ${device_name}(${device_codename}) </b>

<b>Maintainer:</b> ${tg_username}
<b>Build Date:</b> ${date}

<b>Pristine Variant</b>
<b>Download:</b> <a href="${linkp}">Click Here</a>
<b>FileSize:</b> ${sizep}
<b>MD5:</b> <code>${md5p}</code>

<b>GApps Variant</b>
<b>Download:</b> <a href="${linkg}">Click Here</a>
<b>FileSize:</b> ${sizeg}
<b>MD5:</b> <code>${md5g}</code>

#${device_codename} #SicParvisMagna #stagos

Discussions: @HornsOfficial
Releases: @HornsUpdates
EOT

# Send Telegram message
image="/var/lib/jenkins/deviceimg/${device_codename}.png"
telegram-send --format html --image "${image}" --caption "${msg}" --config ~/channel.conf
telegram-send "Build released for ${device}"

echo "${msg}"

# OTA update
cd /var/lib/jenkins/ota
git stash
git pull origin u14 --rebase
git stash pop
git add "${device}/"
git commit -m "[Stag CI] Push OTA for ${device}"
git push -f origin u14