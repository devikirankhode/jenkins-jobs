#!/usr/bin/env bash

set -eo pipefail

export DEIS_CHARTS_BASE_URL="https://charts.deis.com"
export DEIS_CHARTS_BUCKET_BASE_URL="s3://helm-charts"

# publish-helm-chart publishes the given chart to the chart repo determined
# by the given repo_type
publish-helm-chart() {
  local chart="${1}"
  local repo_type="${2}"

  # check out RELEASE_TAG tag (if empty, just stays on master commit)
  short_sha="${SHORT_SHA:-$(git checkout -q "${RELEASE_TAG}" && git rev-parse --short HEAD)}"
  git_tag="${GIT_TAG:-$(git describe --abbrev=0 --tags)}"
  timestamp="${TIMESTAMP:-$(date -u +%Y%m%d%H%M%S)}"
  chart_repo="$(echo "${chart}-${repo_type}" | sed -e 's/-production//g')"

  if [ -d "${PWD}"/charts ]; then
    cd "${PWD}"/charts
    download-and-init-helm

    chart_version="${git_tag}"
    if [ "${chart_repo}" == "${chart}-dev" ]; then
      # treat this as a dev chart: increment patch version (v1.2.3 -> v1.2.4) and add prerelease build info
      incremented_patch_version="$(( ${chart_version: -1} +1))"
      chart_version="${chart_version%?}${incremented_patch_version}-${timestamp}-sha.${short_sha}"
    fi

    update-chart "${chart}" "${chart_version}" "${chart_repo}"

    helm package "${chart}"

    # download index file from aws s3 bucket
    aws s3 cp "${DEIS_CHARTS_BUCKET_BASE_URL}/${chart_repo}/index.yaml" .

    # update index file
    helm repo index . --url "${DEIS_CHARTS_BASE_URL}/${chart_repo}" --merge ./index.yaml

    # push packaged chart and updated index file to aws s3 bucket
    aws s3 cp "${chart}-${chart_version}".tgz "${DEIS_CHARTS_BUCKET_BASE_URL}/${chart_repo}"/ \
      && aws s3 cp --cache-control max_age=0 index.yaml "${DEIS_CHARTS_BUCKET_BASE_URL}/${chart_repo}"/index.yaml \
      && aws s3 cp "${chart}"/values.yaml "${DEIS_CHARTS_BUCKET_BASE_URL}/${chart_repo}/values-${chart_version}".yaml
  else
    echo "No 'charts' directory found at project level; nothing to publish."
  fi
}

# update-chart updates a given chart, using the provided chart, chart_version
# and chart_repo values.  If the chart is 'workflow', a space-delimited list of
# component charts is expected to be present in a WORKFLOW_COMPONENTS env var
update-chart() {
  local chart="${1}"
  local chart_version="${2}"
  local chart_repo="${3}"

  # update the chart version
  perl -i -0pe "s/<Will be populated by the ci before publishing the chart>/${chart_version}/g" "${chart}"/Chart.yaml

  if [ "${chart}" != 'workflow' ]; then
    ## make component chart updates
    if [ "${chart_repo}" != "${chart}-dev" ]; then
      # update all org values to "deis"
      perl -i -0pe 's/"deisci"/"deis"/g' "${chart}"/values.yaml
      # update the image pull policy to "IfNotPresent"
      perl -i -0pe 's/"Always"/"IfNotPresent"/g' "${chart}"/values.yaml
      # update the dockerTag value to chart_version
      perl -i -0pe "s/canary/${chart_version}/g" "${chart}"/values.yaml
    fi
  else
    ## make workflow chart updates
    # update requirements.yaml with correct chart version and chart repo for each component
    for component in ${COMPONENT_CHART_AND_REPOS}; do
      IFS=':' read -r -a chart_and_repo <<< "${component}"
      component_chart="${chart_and_repo[0]}"
      component_repo="${chart_and_repo[1]}"
      latest_tag="$(get-latest-component-release "${component_repo}")"

      component_chart_version="${latest_tag}"
      component_chart_repo="${component_chart}"
      if [ "${chart_version}" != "${git_tag}" ]; then
        # chart version has build data; is -dev variant
        component_chart_version=">=${latest_tag}"
        component_chart_repo="${component_chart}-dev"
      fi
      perl -i -0pe 's/<'"${component_chart}"'-tag>/"'"${component_chart_version}"'"/g' "${chart}"/requirements.yaml
      perl -i -0pe 's='"${DEIS_CHARTS_BASE_URL}/${component_chart}\n"'='"${DEIS_CHARTS_BASE_URL}/${component_chart_repo}\n"'=g' "${chart}"/requirements.yaml
      helm repo add "${component_chart_repo}" "${DEIS_CHARTS_BASE_URL}/${component_chart_repo}"
    done

    # fetch all dependent charts based on above
    helm dependency update "${chart}"

    if [ "${chart_repo}" == "${chart}-staging" ]; then
      # 'stage' chart on production sans index.file (so chart may not be used)
      helm package "${chart}"

      aws s3 cp "${chart}-${chart_version}".tgz "${DEIS_CHARTS_BUCKET_BASE_URL}/${chart}"/ \
        && aws s3 cp "${chart}"/values.yaml "${DEIS_CHARTS_BUCKET_BASE_URL}/${chart}/values-${chart_version}".yaml
    fi

    if [ "${chart_repo}" != "${chart}" ]; then
      # modify workflow-manager/doctor urls in values.yaml to point to staging
      perl -i -0pe "s/versions.deis/versions-staging.deis/g" "${chart}"/values.yaml
      perl -i -0pe "s/doctor.deis/doctor-staging.deis/g" "${chart}"/values.yaml
    fi

    # set WORKFLOW_TAG for downstream e2e job to read from
    echo "WORKFLOW_TAG=${chart_version}" >> "${ENV_FILE_PATH:-/dev/null}"
  fi
}
