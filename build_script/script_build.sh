#!/bin/bash

# Colors makes things beautiful
export TERM=xterm

    red=$(tput setaf 1)             #  red
    grn=$(tput setaf 2)             #  green
    blu=$(tput setaf 4)             #  blue
    cya=$(tput setaf 6)             #  cyan
    txtrst=$(tput sgr0)             #  Reset

# Some variables
maintainer=@$(curl -s "https://api.stag-os.org/maintainers/$device_codename" | jq -r '.data.tg_username')
OUT_PATH="out/target/product/$device_codename"
BUILD_PATH=$(pwd)
export BUILD_TYPE=OFFICIAL
KBUILD_BUILD_USER="StagOS"
KBUILD_BUILD_HOST="Jenkins"
VERSION=14.3.0
export STAG_RELEASE_KEYS=.android-certs/releasekey
export PRODUCT_DEFAULT_DEV_CERTIFICATE=./.android-certs/releasekey

if [[ -z "$device_codename" ]]; then
    echo "Must provide device_codename in environment" 1>&2
    exit 1
fi

# Send message to TG
read -r -d '' msg <<EOT
<b>Build Started</b>
<b>Device:-</b> ${device_codename}
<b>Maintainer:-</b> ${maintainer}
<b>Build Url:-</b> <a href="${BUILD_URL}console">here</a>
EOT

telegram-send --format html "$msg"

# Create folder if doesn't exist
# build: To store the final zip
# target_files: To store the target files used for generating incremental updates
# ota: To store the json files for OTA
[ ! -d "/var/lib/jenkins/builds/${device_codename}" ] && mkdir /var/lib/jenkins/builds/${device_codename}
[ ! -d "/var/lib/jenkins/ota/${device_codename}" ] && mkdir /var/lib/jenkins/ota/${device_codename}
[ ! -d "/var/lib/jenkins/target_files/${device_codename}/cur/" ] && mkdir -p /var/lib/jenkins/target_files/${device_codename}/cur
[ ! -d "/var/lib/jenkins/target_files/${device_codename}/rel/" ] && mkdir -p /var/lib/jenkins/target_files/${device_codename}/rel

# Clean up non releasable builds
rm -rf /var/lib/jenkins/builds/${device_codename}/*
rm -rf /var/lib/jenkins/target_files/${device_codename}/cur/*

# Reset
if [ "${reset}" = "yes" ];
then
rm -rf .repo/local_manifests
rm -rf .repo/projects/device .repo/projects/hardware .repo/projects/kernel .repo/projects/vendor
rm -rf device hardware kernel vendor
echo -e ${cya}"Removing extra/dirty dependencies"${txtrst}
echo -e ${grn}"Syncing fresh sources"${txtrst}
repo sync --force-sync -c --no-tags --no-clone-bundle -j$(nproc --all) --optimized-fetch --prune
echo -e ${grn}"Fresh Sync"${txtrst}
fi

# Ccache
if [ "${use_ccache}" = "yes" ];
then
echo -e ${blu}"CCACHE is enabled for this build"${txtrst}
export CCACHE_EXEC=$(which ccache)
export USE_CCACHE=1
export CCACHE_DIR=/var/lib/jenkins/ccache/${device_codename}
ccache -M 40G
ccache -o compression=true
fi

if [ "${use_ccache}" = "clean" ];
then
export CCACHE_EXEC=$(which ccache)
export CCACHE_DIR=/var/lib/jenkins/ccache/${device_codename}
ccache -C
export USE_CCACHE=1
ccache -M 40G
ccache -o compression=true
wait
echo -e ${grn}"CCACHE Cleared"${txtrst};
fi

rm -rf ${OUT_PATH}/Stag*.zip #clean rom zip in any case

# Initialize build
source build/envsetup.sh

# If lunch fails don't continue
if ! lunch stag_"${device_codename}"-"${release_type}"-"${build_type}"; then
  exit 1
fi

# Make clean
if [ "$make_clean" = "yes" ];
then
make clean
wait
echo -e ${cya}"OUT dir from your repo deleted"${txtrst};
fi

if [ "$make_clean" = "installclean" ];
then
make installclean
wait
echo -e ${cya}"Images deleted from OUT dir"${txtrst};
fi

# Accounting for any vendorsetup changes
. build/envsetup.sh

# If lunch fails don't continue
if ! lunch stag_"${device_codename}"-"${release_type}"-"${build_type}"; then
  exit 1
fi

# .repo/local_manifests/stag_manifest.xml exists then go to all projects and run git lfs pull
if [ -d ".repo/local_manifests" ]; then
    for i in `grep 'path=' .repo/local_manifests/stag_manifest.xml | sed 's/.*path="//;s/".*//'`; do
        cd $i
        git lfs pull
        cd $BUILD_PATH
    done
fi

make stag -j$(nproc --all)

if [ `ls ${OUT_PATH}/StagOS*.zip 2>/dev/null | wc -l` != "0" ]; then
RESULT=Success
cd ${OUT_PATH}
RZIP="$(ls StagOS*.zip)"
DATETIME="$(grep ro.build.date.utc system/build.prop | cut -d= -f2)"
cp ${RZIP} /var/lib/jenkins/builds/${device_codename}/

test_link="https://test.stag-os.org/${device_codename}/${RZIP}"

read -r -d '' msg <<EOT
<b>Pristine Build Completed</b>
<b>Device:-</b> ${device_codename}
<b>Maintainer:-</b> ${maintainer}
<b>Download:-</b> <a href="${test_link}">here</a>
EOT

telegram-send --format html "$msg"
else
telegram-send "Build for ${device_codename} failed. ${maintainer}"
exit 1
fi

if [ "${RESULT}" = "Success" ];
then

$BUILD_PATH/vendor/stag/tools/json.sh ${RZIP} full_update_pristine.json
cp full_update_pristine.json /var/lib/jenkins/ota/${device_codename}/full_update_pristine.json

CUR_TARGET_FOL=${RZIP::-4}-target_files

cp obj/PACKAGING/target_files_intermediates/${CUR_TARGET_FOL} /var/lib/jenkins/target_files/${device_codename}/cur/
echo -e ${grn}"Target zip for pristine copied"${txtrst};

cd $BUILD_PATH
export WITH_GAPPS=true
echo "Gapps" > build_type
. build/envsetup.sh
lunch stag_"${device_codename}"-"${release_type}"-"${build_type}"
make installclean
make stag -j$(nproc --all)

cd ${OUT_PATH}
RZIP="$(ls StagOS*GApps*.zip)"
DATETIME="$(grep ro.build.date.utc system/build.prop | cut -d= -f2)"
cp ${RZIP} /var/lib/jenkins/builds/${device_codename}/
test_link="https://test.stag-os.org/$device_codename/$RZIP"

$BUILD_PATH/vendor/stag/tools/json.sh ${RZIP} full_update_gapps.json
cp full_update_gapps.json /var/lib/jenkins/ota/${device_codename}/full_update_gapps.json

CUR_TARGET_FOL=${RZIP::-4}-target_files

cp obj/PACKAGING/target_files_intermediates/${CUR_TARGET_FOL} /var/lib/jenkins/target_files/${device_codename}/cur/
echo -e ${grn}"Target zip for gapps copied"${txtrst};

telegram-send "Builds done ${maintainer}"

cd ~/imageEdit
python3 imageEdit.py ${device_codename}
mv ${device_codename}.png ~/deviceimg/${device_codename}.png

telegram-send "Banner for ${device_codename} created"

else
exit 1
fi
