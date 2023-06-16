#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DEFAULT_DELETE_FORCE="false"

show_help() {
cat << EOF
Usage: $(basename "$0") <options>

    -h, --help                Display help
    -t, --type                Operation type
                                1) remove v prefix
                                2) replace '-' with '.'
                                3) get release asset upload url
                                4) get latest release tag
                                5) update release latest
                                6) get the ci trigger mode
                                7) trigger other repo actions workflow
                                8) delete release version
                                9) delete release charts
                                10) delete docker images
                                11) delete aliyun images
    -tn, --tag-name           Release tag name
    -gr, --github-repo        Github Repo
    -gt, --github-token       Github token
    -bn, --branch-name        The branch name that triggers the workflow
    -wi, --workflow-id        The workflow id that triggers the workflow
    -v, --version             Release version
    -u, --user                The docker registry user
    -p, --password            The docker registry password
    -df, --delete-force       Force to delete stable release (default: DEFAULT_DELETE_FORCE)
EOF
}

GITHUB_API="https://api.github.com"
LATEST_REPO=apecloud/kubeblocks

main() {
    local TYPE
    local TAG_NAME=""
    local GITHUB_REPO
    local GITHUB_TOKEN
    local TRIGGER_MODE=""
    local BRANCH_NAME="main"
    local WORKFLOW_ID=""
    local VERSION=""
    local USER=""
    local PASSWORD=""
    local STABLE_RET
    local DELETE_FORCE=$DEFAULT_DELETE_FORCE

    parse_command_line "$@"

    local TAG_NAME_TMP=${TAG_NAME/v/}

    case $TYPE in
        8|9|10|11)
            STABLE_RET=$( check_stable_release )
            if [[ -z "$TAG_NAME" || ("$STABLE_RET" == "1" && "$DELETE_FORCE" == "false") ]]; then
                echo "skip delete stable release $TAG_NAME"
                return
            fi
        ;;
    esac
    case $TYPE in
        1)
            echo "${TAG_NAME/v/}"
        ;;
        2)
            echo "${TAG_NAME/-/.}"
        ;;
        3)
            get_upload_url
        ;;
        4)
            get_latest_tag
        ;;
        5)
            update_release_latest
        ;;
        6)
            get_trigger_mode
        ;;
        7)
            trigger_repo_workflow
        ;;
        8)
            delete_release_version
        ;;
        9)
            delete_release_charts
        ;;
        10)
            delete_docker_images
        ;;
        11)
            delete_aliyun_images
        ;;
        *)
            show_help
            break
        ;;
    esac
}

parse_command_line() {
    while :; do
        case "${1:-}" in
            -h|--help)
                show_help
                exit
                ;;
            -t|--type)
                if [[ -n "${2:-}" ]]; then
                    TYPE="$2"
                    shift
                fi
                ;;
            -tn|--tag-name)
                if [[ -n "${2:-}" ]]; then
                    TAG_NAME="$2"
                    shift
                fi
                ;;
            -gr|--github-repo)
                if [[ -n "${2:-}" ]]; then
                    GITHUB_REPO="$2"
                    shift
                fi
                ;;
            -gt|--github-token)
                if [[ -n "${2:-}" ]]; then
                    GITHUB_TOKEN="$2"
                    shift
                fi
                ;;
            -bn|--branch-name)
                if [[ -n "${2:-}" ]]; then
                    BRANCH_NAME="$2"
                    shift
                fi
                ;;
            -wi|--workflow-id)
                if [[ -n "${2:-}" ]]; then
                    WORKFLOW_ID="$2"
                    shift
                fi
                ;;
            -v|--version)
                if [[ -n "${2:-}" ]]; then
                    VERSION="$2"
                    shift
                fi
                ;;
            -u|--user)
                if [[ -n "${2:-}" ]]; then
                    USER="$2"
                    shift
                fi
                ;;
            -p|--password)
                if [[ -n "${2:-}" ]]; then
                    PASSWORD="$2"
                    shift
                fi
                ;;
            -df|--delete-force)
                if [[ -n "${2:-}" ]]; then
                    DELETE_FORCE="$2"
                    shift
                fi
                ;;
            *)
                break
                ;;
        esac

        shift
    done
}

gh_curl() {
    curl -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3.raw" \
      $@
}

get_upload_url() {
    gh_curl -s $GITHUB_API/repos/$GITHUB_REPO/releases/tags/$TAG_NAME > release_body.json
    echo $(jq '.upload_url' release_body.json) | sed 's/\"//g'
}

get_latest_tag() {
    latest_release_tag=`gh_curl -s $GITHUB_API/repos/$LATEST_REPO/releases/latest | jq -r '.tag_name'`
    echo $latest_release_tag
}

update_release_latest() {
    release_id=`gh_curl -s $GITHUB_API/repos/$GITHUB_REPO/releases/tags/$TAG_NAME | jq -r '.id'`

    gh_curl -X PATCH \
        $GITHUB_API/repos/$GITHUB_REPO/releases/$release_id \
        -d '{"draft":false,"prerelease":false,"make_latest":true}'
}

add_trigger_mode() {
    trigger_mode=$1
    if [[ "$TRIGGER_MODE" != *"$trigger_mode"* ]]; then
        TRIGGER_MODE=$trigger_mode$TRIGGER_MODE
    fi
}

trigger_repo_workflow() {
    data='{"ref":"'$BRANCH_NAME'"}'
    if [[ ! -z "$VERSION" ]]; then
        data='{"ref":"main","inputs":{"VERSION":"'$VERSION'"}}'
    fi
    gh_curl -X POST \
        $GITHUB_API/repos/$GITHUB_REPO/actions/workflows/$WORKFLOW_ID/dispatches \
        -d $data
}

get_trigger_mode() {
    for filePath in $( git diff --name-only HEAD HEAD^ ); do
        if [[ "$filePath" == "go."* ]]; then
            add_trigger_mode "[test]"
            continue
        elif [[ "$filePath" != *"/"* ]]; then
            add_trigger_mode "[other]"
            continue
        fi

        case $filePath in
            docs/*)
                add_trigger_mode "[docs]"
            ;;
            docker/*)
                add_trigger_mode "[docker]"
            ;;
            deploy/*)
                add_trigger_mode "[deploy]"
            ;;
            .github/*|.devcontainer/*|githooks/*|examples/*)
                add_trigger_mode "[other]"
            ;;
            internal/cli/cmd/*)
                add_trigger_mode "[cli][test]"
            ;;
            *)
                add_trigger_mode "[test]"
            ;;
        esac
    done
    echo $TRIGGER_MODE
}

check_stable_release() {
    release_tag="v"*"."*"."*
    not_stable_release_tag="v"*"."*"."*"-"*
    if [[ -z "$TAG_NAME" || ("$TAG_NAME" == $release_tag && "$TAG_NAME" != $not_stable_release_tag) ]]; then
        echo "1"
    else
        echo "0"
    fi
}

delete_release_version() {
    release_id=$( gh_curl -s $GITHUB_API/repos/$GITHUB_REPO/releases/tags/$TAG_NAME | jq -r '.id' )
    if [[ -n "$release_id" && "$release_id" != "null" ]]; then
        echo "delete $GITHUB_REPO release $TAG_NAME"
        gh_curl -s -X DELETE $GITHUB_API/repos/$GITHUB_REPO/releases/$release_id
    fi
    echo "delete $GITHUB_REPO tag $TAG_NAME"
    gh_curl -s -X DELETE  $GITHUB_API/repos/$GITHUB_REPO/git/refs/tags/$TAG_NAME
}

filter_charts() {
    while read -r chart; do
        [[ ! -d "$charts_dir/$chart" ]] && continue
        local file="$charts_dir/$chart/Chart.yaml"
        if [[ -f "$file" ]]; then
            chart_name=$(cat $file | grep "name:"|awk 'NR==1{print $2}')
            echo "delete chart $chart_name-$TAG_NAME_TMP"
            TAG_NAME="$chart_name-$TAG_NAME_TMP"
            delete_release_version &
        fi
    done
}

delete_release_charts() {
    local charts_dir=deploy
    charts_files=$( ls -1 $charts_dir )
    echo "$charts_files" | filter_charts
    wait
}

delete_docker_images() {
    echo "delete kubeblocks image $TAG_NAME_TMP"
    docker run --rm -it apecloud/remove-dockerhub-tag \
        --user "$USER" --password "$PASSWORD" \
        apecloud/kubeblocks:$TAG_NAME_TMP

    echo "delete kubeblocks-tools image $TAG_NAME_TMP"
    docker run --rm -it apecloud/remove-dockerhub-tag \
        --user "$USER" --password "$PASSWORD" \
        apecloud/kubeblocks-tools:$TAG_NAME_TMP
}

delete_aliyun_images() {
    echo "delete kubeblocks image $TAG_NAME_TMP"
    skopeo delete docker://registry.cn-hangzhou.aliyuncs.com/apecloud/kubeblocks:$TAG_NAME_TMP \
        --creds "$USER:$PASSWORD"

    echo "delete kubeblocks-tools image $TAG_NAME_TMP"
    skopeo delete docker://registry.cn-hangzhou.aliyuncs.com/apecloud/kubeblocks-tools:$TAG_NAME_TMP \
        --creds "$USER:$PASSWORD"
}

main "$@"