#!/usr/bin/env bash
#
# Copyright The CloudNativePG Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=("$@")
if [ ${#versions[@]} -eq 0 ]; then
	for version in */; do
		[[ $version = src/ ]] && continue
		versions+=("$version")
	done
fi
versions=("${versions[@]%/}")

# Update this everytime a new major release of PostgreSQL is available
POSTGRESQL_LATEST_MAJOR_RELEASE=17

# Get the last postgres base image tag and update time
fetch_postgres_image_version() {
	local version="$1";
	local item="$2";

	regexp="^${version}-[0-9.]+$"
	if [[ ${version} -gt "${POSTGRESQL_LATEST_MAJOR_RELEASE}" ]]; then
		regexp="^${version}beta[0-9]+-master$"
	fi

	curl -SsL "https://registry.hub.docker.com/v2/repositories/postgis/postgis/tags/?name=${version}&ordering=last_updated&" | \
		jq --arg regexp "$regexp" -c '.results[] | select( .name | match($regexp))' | \
		jq -r ".${item}" | \
		sort -r | \
		head -n1
}

# Get the latest Barman version
latest_barman_version=
_raw_get_latest_barman_version() {
#	curl -s https://pypi.org/pypi/barman/json | jq -r '.releases | keys[]' | sort -Vr | head -n1
	echo "3.12.1"
}
get_latest_barman_version() {
	if [ -z "$latest_barman_version" ]; then
		latest_barman_version=$(_raw_get_latest_barman_version)
	fi
	echo "$latest_barman_version"
}

# record_version(versionFile, component, componentVersion)
# Parameters:
#   versionFile: the file containing the version of each component
#   component: the component to be updated
#   componentVersion: the new component version to be set
record_version() {
	local versionFile="$1"; shift
	local component="$1"; shift
	local componentVersion="$1"; shift

	jq -S --arg component "${component}" \
		--arg componentVersion "${componentVersion}" \
		'.[$component] = $componentVersion' <"${versionFile}" >>"${versionFile}.new"

	mv "${versionFile}.new" "${versionFile}"
}

generate_postgres() {
	local version="$1"; shift
	versionFile="${version}/.versions.json"
	imageReleaseVersion=1

	postgisImageVersion=$(fetch_postgres_image_version "${version}" "name")
	if [ -z "$postgisImageVersion" ]; then
		echo "Unable to retrieve latest postgres ${version} image version"
		exit 1
	fi

	postgisImageLastUpdate=$(fetch_postgres_image_version "${version}" "last_updated")
	if [ -z "$postgisImageLastUpdate" ]; then
		echo "Unable to retrieve latest  postgis ${version} image version last update time"
		exit 1
	fi

	barmanVersion=$(get_latest_barman_version)
	if [ -z "$barmanVersion" ]; then
		echo "Unable to retrieve latest barman-cli-cloud version"
		exit 1
	fi

	dockerTemplate="Dockerfile.template"
	if [[ ${version} -gt "${POSTGRESQL_LATEST_MAJOR_RELEASE}" ]]; then
		dockerTemplate="Dockerfile-beta.template"
	fi

	# Update requirements.txt
	cp -r src/* "$version/"

	# Output the image being updated
	echo "$postgisImageVersion"

	if [ -f "${versionFile}" ]; then
		oldImageReleaseVersion=$(jq -r '.IMAGE_RELEASE_VERSION' "${versionFile}")
		oldBarmanVersion=$(jq -r '.BARMAN_VERSION' "${versionFile}")
		oldPostgisImageLastUpdate=$(jq -r '.POSTGIS_IMAGE_LAST_UPDATED' "${versionFile}")
		oldPostgisImageVersion=$(jq -r '.POSTGIS_IMAGE_VERSION' "${versionFile}")
		imageReleaseVersion=$oldImageReleaseVersion
	else
		imageReleaseVersion=1
		echo "{}" > "${versionFile}"
		record_version "${versionFile}" "IMAGE_RELEASE_VERSION" "${imageReleaseVersion}"
		record_version "${versionFile}" "BARMAN_VERSION" "${barmanVersion}"
		record_version "${versionFile}" "POSTGIS_IMAGE_LAST_UPDATED" "${postgisImageLastUpdate}"
		record_version "${versionFile}" "POSTGIS_IMAGE_VERSION" "${postgisImageVersion}"
		return
	fi

	newRelease="false"

	# Detect an update of the postgis image
	if [ "$oldPostgisImageLastUpdate" != "$postgisImageLastUpdate" ]; then
		echo "Postgis image timestamp changed from $oldPostgisImageLastUpdate to $postgisImageLastUpdate"
		newRelease="true"
		record_version "${versionFile}" "POSTGIS_IMAGE_LAST_UPDATED" "${postgisImageLastUpdate}"
	fi

	# Detect an update of Barman
	if [ "$oldBarmanVersion" != "$barmanVersion" ]; then
		echo "Barman changed from $oldBarmanVersion to $barmanVersion"
		newRelease="true"
		record_version "${versionFile}" "BARMAN_VERSION" "${barmanVersion}"
	fi

	# Detect an update of Dockerfile template
	if [[ -n $(git diff --name-status "$dockerTemplate") ]]; then
		echo "Detected update of $dockerTemplate"
		newRelease="true"
	fi

	# Detect an update of requirements.txt
	if [[ -n $(git diff --name-status "$version/requirements.txt") ]]; then
		echo "Detected update of requirements.txt dependencies"
		newRelease="true"
	fi

	if [ "$oldPostgisImageVersion" != "$postgisImageVersion" ]; then
		echo "PostGIS base image changed from $oldPostgisImageVersion to $postgisImageVersion"
		record_version "${versionFile}" "IMAGE_RELEASE_VERSION" 1
		record_version "${versionFile}" "POSTGIS_IMAGE_VERSION" "${postgisImageVersion}"
		imageReleaseVersion=1
	elif [ "$newRelease" = "true" ]; then
		imageReleaseVersion=$((oldImageReleaseVersion + 1))
		record_version "${versionFile}" "IMAGE_RELEASE_VERSION" $imageReleaseVersion
	fi

	sed -e 's/%%POSTGIS_IMAGE_VERSION%%/'"$postgisImageVersion"'/g' \
		-e 's/%%IMAGE_RELEASE_VERSION%%/'"$imageReleaseVersion"'/g' \
		"${dockerTemplate}" \
		> "$version/Dockerfile"
}

update_requirements() {
	barmanVersion=$(get_latest_barman_version)
	# If there's a new version we need to recreate the requirements files
	echo "barman[cloud,azure,snappy,google,zstandard,lz4] == $barmanVersion" > requirements.in
	echo "boto3 == 1.35.99" >> requirements.in

	# This will take the requirements.in file and generate a file
	# requirements.txt with the hashes for the required packages
	pip-compile --generate-hashes 2> /dev/null

	# Removes psycopg from the list of packages to install
	sed -i '/psycopg/{:a;N;/barman/!ba};/via barman/d' requirements.txt

	# Then the file needs to be moved into the src/root/ that will
	# be added to every container later
	mv requirements.txt src/
}

update_requirements
for version in "${versions[@]}"; do
	generate_postgres "${version}"
done
