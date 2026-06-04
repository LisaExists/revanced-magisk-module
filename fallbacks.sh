#!/usr/bin/env bash
# shellcheck shell=bash

# This file is sourced after utils.sh. It overrides get_prebuilts() and adds:
# - ReVanced API fallback for release patches
# - GitLab source build fallback for dev patches

_get_latest_gitlab_patches_tag() {
  local src=${1:?missing source}
  local api_url="https://gitlab.com/api/v4/projects/ReVanced%2Frevanced-patches/releases/permalink/latest"
  local resp tag

  resp=$(gh_req "$api_url" -) || return 1
  tag=$(jq -r '.tag_name // .tag // .name // empty' <<<"$resp") || return 1

  if [ -z "$tag" ]; then
    epr "GitLab returned no release tag for ${src}"
    return 1
  fi

  echo "$tag"
}

_build_gitlab_dev_patches() {
  local src=${1:?missing source}
  local cache_dir=${2:?missing cache dir}
  local tag archive_url archive_file unpack_dir root_dir built_file cached_file repo_name

  tag=$(_get_latest_gitlab_patches_tag "$src") || return 1
  repo_name=${src##*/}
  cached_file="${cache_dir}/ReVanced-${repo_name}-${tag#v}.rvp"

  if [ -f "$cached_file" ]; then
    echo "$cached_file"
    return 0
  fi

  archive_url="https://gitlab.com/${src}/-/archive/${tag}/${repo_name}-${tag}.zip"
  archive_file="${cache_dir}/${repo_name}-${tag}.zip"
  unpack_dir="${cache_dir}/${repo_name}-${tag}"

  rm -rf "$unpack_dir" "$archive_file"
  gh_dl "$archive_file" "$archive_url" >&2 || return 1
  mkdir -p "$unpack_dir"
  unzip -qo "$archive_file" -d "$unpack_dir" || return 1

  root_dir=$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
  if [ -z "$root_dir" ]; then
    epr "Could not locate the extracted GitLab source directory"
    return 1
  fi

  (
    cd "$root_dir" || exit 1
    ./gradlew --no-daemon buildAndroid
  ) || return 1

  built_file=$(find "$root_dir" -type f -path '*/build/libs/*.rvp' | sort | tail -1)
  if [ -z "$built_file" ]; then
    epr "GitLab build completed, but no .rvp file was produced"
    return 1
  fi

  mkdir -p "$cache_dir"
  cp -f "$built_file" "$cached_file" || return 1
  echo "$cached_file"
}

_download_revanced_api_patches() {
  local src=${1:?missing cache dir}
  local api_base=${REVANCED_API_BASE:-https://api.revanced.app}
  local endpoint payload version url file candidate

  for endpoint in \
    "$api_base/v5/patches"
  do
    payload=$(gh_req "$endpoint" -) || continue

    version=$(jq -r '
      .version // .tag_name // .tagName //
      .patches.version // .patches.tag_name // .patches.tagName //
      .release.version // .release.tag_name // empty
    ' <<<"$payload") || continue

    url=$(jq -r '
      .download_url // .downloadUrl // .url //
      .patches.download_url // .patches.downloadUrl // .patches.url //
      .patch.download_url // .patch.downloadUrl // .patch.url //
      .asset.download_url // .asset.downloadUrl // .asset.url //
      .release.download_url // .release.downloadUrl // .release.url // empty
    ' <<<"$payload") || continue

    if [ -z "$url" ]; then
      candidate=$(jq -r '
        .. | objects |
        (.browser_download_url? // .download_url? // .downloadUrl? // empty)
      ' <<<"$payload" | awk 'NF { print; exit }')
      url=${candidate:-}
    fi

    [ -n "$url" ] || continue

    version=${version:-latest}
    file="${src}/ReVanced-revanced-patches-${version#v}.rvp"
    gh_dl "$file" "$url" >&2 || continue
    echo "$file"
    return 0
  done

  epr "ReVanced API fallback was unavailable"
  return 1
}

_get_release_prebuilt() {
  local src=${1:?missing source}
  local ver=${2:?missing version}
  local fprefix=${3:?missing prefix}
  local cache_dir=${4:?missing cache dir}
  local tag_url rel_url name_ver file resp tag_name matches asset url name

  rel_url="https://api.github.com/repos/${src}/releases"

  if [ "$ver" = "dev" ]; then
    resp=$(gh_req "$rel_url" -) || return 1
    ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
  fi

  if [ "$ver" = "latest" ]; then
    rel_url+="/latest"
    name_ver="*"
  else
    rel_url+="/tags/${ver}"
    name_ver="$ver"
  fi

  file=$(find "$cache_dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null)
  if [ "$ver" = "latest" ]; then
    file=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" | head -1)
  else
    file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | head -1)
  fi

  if [ -n "$file" ]; then
    echo "$file"
    return 0
  fi

  resp=$(gh_req "$rel_url" -) || return 1
  tag_name=$(jq -r '.tag_name' <<<"$resp") || return 1
  matches=$(jq -e '.assets | map(select(.name | (endswith("asc") or endswith("json")) | not))' <<<"$resp") || return 1

  if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
    local matches_new
    matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
    if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
      matches=$matches_new
    fi
  fi

  if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
    epr "No asset was found for ${src}@${ver}"
    return 1
  elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
    wpr "More than 1 asset was found for ${src}@${ver}. Falling back to the first one found..."
  fi

  asset=$(jq -r '.[0]' <<<"$matches")
  url=$(jq -r '.url' <<<"$asset")
  name=$(jq -r '.name' <<<"$asset")
  file="${cache_dir}/${name}"

  gh_dl "$file" "$url" >&2 || return 1
  echo "$file"
}

get_prebuilts() {
  local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
  local cl_dir=${patches_src%/*}
  cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
  mkdir -p "$cl_dir"

  pr "Getting prebuilts (${patches_src%/*})" >&2

  local cli_jar patches_jar
  cli_jar=$(_get_release_prebuilt "$cli_src" "$cli_ver" cli "$cl_dir") || return 1

  if [[ "${patches_src,,}" == "revanced/revanced-patches" && "$patches_ver" == "dev" ]]; then
    patches_jar=$(_build_gitlab_dev_patches "$patches_src" "$cl_dir") || return 1
  else
    if ! patches_jar=$(_get_release_prebuilt "$patches_src" "$patches_ver" patches "$cl_dir"); then
      if [[ "${patches_src,,}" == "revanced/revanced-patches" ]]; then
        wpr "GitHub release for ReVanced patches was unavailable; falling back to ReVanced API"
        patches_jar=$(_download_revanced_api_patches "$cl_dir") || return 1
      else
        return 1
      fi
    fi
  fi

  echo "$cli_jar $patches_jar"
}
