#!/bin/bash

set -e

CHANNEL="stable"

# Each available component shall be in only one of the lists below
AVAILABLE_COMPONENTS="\
mender-client \
mender-configure \
mender-configure-demo \
mender-configure-timezone \
mender-connect \
mender-monitor \
mender-monitor-demo \
"

DEFAULT_COMPONENTS="\
mender-client \
mender-configure \
mender-connect \
"

DEMO_COMPONENTS="\
mender-configure-demo \
mender-configure-timezone \
"

COMMERCIAL_COMPONENTS="\
mender-monitor \
"

COMMERCIAL_DEMO_COMPONENTS="\
mender-monitor-demo \
"

SELECTED_COMPONENTS="$DEFAULT_COMPONENTS"
DEMO="0"

# Path where to install the Mender APT repository
MENDER_APT_SOURCES_LIST="/etc/apt/sources.list.d/mender.list"

# URL prefix from where to download commercial compoments
MENDER_COMMERCIAL_DOWNLOAD_URL="https://downloads.customer.mender.io/content/hosted/"

# URL path for the actual components, formatted by version
declare -A COMMERCIAL_COMP_TO_URL_PATH_F=(
  [mender-monitor]="mender-monitor/debian/%s/mender-monitor_%s-1_all.deb"
  [mender-monitor-demo]="mender-monitor/debian/%s/mender-monitor-demo_%s-1_all.deb"
)

export DEBIAN_FRONTEND=noninteractive

banner (){
    echo "
                          _
 _ __ ___   ___ _ __   __| | ___ _ __
| '_ \` _ \ / _ \ '_ \ / _\` |/ _ \ '__|
| | | | | |  __/ | | | (_| |  __/ |
|_| |_| |_|\___|_| |_|\__,_|\___|_|

Running the Mender installation script.
--
"

}

usage() {
    echo "usage: install-mender.sh [options] [component...] [-- [options-for-mender-setup] ]"
    echo ""
    echo "options: [-h, help] [-c channel] [--demo] [--commercial]"
    echo "  -h, --help          print this help"
    echo "  -c CHANNEL          channel: stable(default)|experimental"
    echo "  --demo              use defaults appropriate for demo"
    echo "  --commercial        install commercial components, requires --jwt-token"
    echo "  --jwt-token TOKEN   Hosted Mender JWT token"
    echo ""
    echo "If no components are specified, defaults will be installed"
    echo ""
    echo "Anything after a '--' gets passed directly to 'mender setup' command."
    echo ""
    echo "Supported components (x = installed by default):"
    for c in $AVAILABLE_COMPONENTS; do
        if echo "$DEFAULT_COMPONENTS" | egrep -q "(^| )$c( |\$)"; then
            echo -n " (x) "
        else
            echo -n " (-) "
        fi
        echo "$c"
    done
}

is_known_component() {
    for known in $AVAILABLE_COMPONENTS; do
        if [ "$1" = "$known" ]; then
            return 0
        fi
    done
    return 1
}

parse_args() {
    local selected_components=""
    local args_copy="$@"
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -c)
                if [ -n "$2" ]; then
                    CHANNEL="$2"
                    shift
                else
                    echo "ERROR: channel requires a non-empty option argument."
                    echo "Aborting."
                    exit 1
                fi
                ;;
            --demo)
                DEMO="1"
                SELECTED_COMPONENTS="$SELECTED_COMPONENTS $DEMO_COMPONENTS"
                ;;
            --commercial)
                if [[ ! "$args_copy" == *"--jwt-token"* ]]; then
                    echo "ERROR: commercial requires --jwt-token argument."
                    echo "Aborting."
                    exit 1
                fi
                SELECTED_COMPONENTS="$SELECTED_COMPONENTS $COMMERCIAL_COMPONENTS"
                if [[ "$args_copy" == *"--demo"* ]]; then
                    SELECTED_COMPONENTS="$SELECTED_COMPONENTS $COMMERCIAL_DEMO_COMPONENTS"
                fi
                ;;
            --jwt-token)
                if [ -n "$2" ]; then
                    JWT_TOKEN="$2"
                    shift
                else
                    echo "ERROR: jwt-token requires a non-empty option argument."
                    echo "Aborting."
                    exit 1
                fi
                ;;
            --)
                shift
                MENDER_SETUP_ARGS="$@"
                break
                ;;
            *)
                if is_known_component "$1"; then
                    if echo "$COMMERCIAL_COMPONENTS" | egrep -q "(^| )$1( |\$)"; then
                        if [[ ! "$args_copy" == *"--jwt-token"* ]]; then
                            echo "ERROR: $1 requires --jwt-token argument."
                            echo "Aborting."
                            exit 1
                        fi
                    fi
                    selected_components="$selected_components $1 "
                else
                    echo "Unsupported argument: \`$1\`"
                    echo "Run \`mender-install.sh -h\` for help."
                    echo "Aborting."
                    exit 1
                fi
                ;;
        esac
        shift
    done
    if [ -n "$selected_components" ]; then
        SELECTED_COMPONENTS="$selected_components"
    fi
}

print_components() {
    echo "  Selected components:"
    for c in $SELECTED_COMPONENTS; do
        printf "\t%s\n" "$c"
    done
}

init() {
    REPO_URL=https://downloads.mender.io/repos/debian

    parse_args "$@"

    ARCH=$(dpkg --print-architecture)
    echo "  Detected architecture:"
    printf "\t%s\n" "$ARCH"

    echo "  Installing from channel:"
    printf "\t%s\n" "$CHANNEL"
}

get_deps() {
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg
}

add_repo() {
    curl -fsSL $REPO_URL/gpg | apt-key add -

    local repo_deprecated="deb [arch=$ARCH] $REPO_URL $CHANNEL main"
    if grep -F "$repo_deprecated" /etc/apt/sources.list >/dev/null; then
        echo "ERROR: deprecated repository found in apt sources lists."
        echo "Please remove it manually with: sudo sed -i.bak -e \"\,$repo_deprecated,d\" /etc/apt/sources.list"
        echo "See https://docs.mender.io for updated APT repos information"
        exit 1
    fi
    if test -f "$MENDER_APT_SOURCES_LIST" && \
            grep -F "$repo_deprecated" "$MENDER_APT_SOURCES_LIST" >/dev/null; then
        echo "ERROR: deprecated repository found in apt sources lists."
        echo "Please remove it manually with: sudo rm $MENDER_APT_SOURCES_LIST"
        echo "See https://docs.mender.io for updated APT repos information"
        exit 1
    fi

    local repo_dist=""
    if [[ "$LSB_DIST" == "raspbian" ]]; then
        repo_dist="debian"
    else
        repo_dist="$LSB_DIST"
    fi

    local repo="deb [arch=$ARCH] $REPO_URL $repo_dist/$DIST_VERSION/$CHANNEL main"
    echo "Installing Mender APT repository at $MENDER_APT_SOURCES_LIST..."
    echo "$repo" > "$MENDER_APT_SOURCES_LIST"
}

do_install_open() {
    # Filter out commercial components
    local selected_components_open=""
    for c in $SELECTED_COMPONENTS; do
        if ! echo "$COMMERCIAL_COMPONENTS $COMMERCIAL_DEMO_COMPONENTS" | egrep -q "(^| )$c( |\$)"; then
            selected_components_open="$selected_components_open $c"
        fi
    done

    # Return if no open source components selected
    if [ -z "$selected_components_open" ]; then
        return
    fi

    echo "  Installing open source components from APT repository"

    apt-get update
    apt-get install -y \
       -o Dpkg::Options::="--force-confdef" \
       -o Dpkg::Options::="--force-confold" \
       $selected_components_open

    echo "  Success! Please run \`mender setup\` to configure the client."
}

do_install_commercial() {
    # Filter commercial components
    local selected_components_commercial=""
    for c in $SELECTED_COMPONENTS; do
        if echo "$COMMERCIAL_COMPONENTS $COMMERCIAL_DEMO_COMPONENTS" | egrep -q "(^| )$c( |\$)"; then
            selected_components_commercial="$selected_components_commercial $c"
        fi
    done

    # Return if no commercial components selected
    if [ -z "$selected_components_commercial" ]; then
        return
    fi

    echo "  Installing commercial components from $MENDER_COMMERCIAL_DOWNLOAD_URL"

    # Translate Debian "channel" into Mender version
    if [ "$CHANNEL" = "experimental" ]; then
        version="master"
    else
        version="latest"
    fi

    # Download deb packages
    for c in $selected_components_commercial; do
        url="$MENDER_COMMERCIAL_DOWNLOAD_URL$(printf ${COMMERCIAL_COMP_TO_URL_PATH_F[$c]} $version $version)"
        curl -fLsS -H "Authorization: Bearer $JWT_TOKEN" -O "$url" ||
                (echo ERROR: Cannot get $c from $url; exit 1)
    done

    # Install all of them at once and fallback to install missing dependencies
    local deb_packages_glob=$(echo $selected_components_commercial | sed -e 's/ /*.deb /g; s/$/*.deb/')
    dpkg --install $deb_packages_glob || apt-get -f -y install

    # Check individually each package
    for c in $selected_components_commercial; do
        dpkg --status $c || (echo ERROR: $c could not be installed; exit 1)
    done

    echo "  Success!"
}

do_setup_mender() {
    # Return if mender-client was not installed
    if [[ ! "$SELECTED_COMPONENTS" == *"mender-client"* ]]; then
        return
    fi

    # Return if no setup options were passed
    if [ -z "$MENDER_SETUP_ARGS" ]; then
        return
    fi

    echo "  Setting up mender with options: $MENDER_SETUP_ARGS"
    mender setup $MENDER_SETUP_ARGS
    pidof systemd && systemctl restart mender-client
    echo "  Success!"
}

do_setup_addons() {
    # Setup for mender-connect
    if [[ "$SELECTED_COMPONENTS" == *"mender-connect"* ]]; then
        if [ "$DEMO" -eq 1 ]; then
            echo "  Setting up mender-connect with user 'root' and shell 'bash'"
            cat > /etc/mender/mender-connect.conf << EOF
{
  "User": "root",
  "ShellCommand": "/bin/bash"
}
EOF
            pidof systemd && systemctl restart mender-connect
            echo "  Success!"
        fi
    fi
}

do_install_missing_monitor_dirs () {
    if [[ "$SELECTED_COMPONENTS" == *"mender-monitor-demo"* ]]; then
        mkdir -p /etc/mender-monitor/monitor.d/enabled || true
        mkdir -p /etc/mender-monitor/monitor.d/available || true
    fi
}

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# Set the LSB_DIST and DIST_VERSION variables guessing the distribution and version;
# It also checks if this is a forked Linux distro.
# Credits: https://get.docker.com/
check_dist_and_version() {
    # Every system that we officially support has /etc/os-release
    if [ -r /etc/os-release ]; then
        LSB_DIST="$(. /etc/os-release && echo "$ID" | tr '[:upper:]' '[:lower:]')"
    fi
    case "$LSB_DIST" in
        ubuntu)
            if command_exists lsb_release; then
                DIST_VERSION="$(lsb_release --codename | cut -f2)"
            fi
            if [ -z "$DIST_VERSION" ] && [ -r /etc/lsb-release ]; then
                DIST_VERSION="$(. /etc/lsb-release && echo "$DISTRIB_CODENAME")"
            fi
            case "$DIST_VERSION" in
                focal)
                    DIST_VERSION="focal"
                ;;
                bionic)
                    DIST_VERSION="bionic"
                ;;
                *)
                    echo "ERROR: your distribution's version ($DIST_VERSION) is either not recognized or not supported."
                    echo "Aborting."
                    exit 1
                ;;
            esac
        ;;
        debian|raspbian)
            DIST_VERSION="$(sed 's/\/.*//' /etc/debian_version | sed 's/\..*//')"
            case "$DIST_VERSION" in
                11)
                    DIST_VERSION="bullseye"
                ;;
                10)
                    DIST_VERSION="buster"
                ;;
                *)
                    echo "ERROR: your distribution's version ($DIST_VERSION) is either not recognized or not supported."
                    echo "Aborting."
                    exit 1
                ;;
            esac
        ;;
        *)
            echo "ERROR: your distribution ($LSB_DIST) is either not recognized or not supported."
            echo "Aborting."
            exit 1
        ;;
    esac

    # Check for lsb_release command existence, it usually exists in forked distros
    if command_exists lsb_release; then
        # Check if the `-u` option is supported
        set +e
        lsb_release -a -u > /dev/null 2>&1
        lsb_release_exit_code=$?
        set -e

        # Check if the command has exited successfully, it means we're in a forked distro
        if [ "$lsb_release_exit_code" = "0" ]; then
            # Get the upstream release info
            LSB_DIST=$(lsb_release -a -u 2>&1 | tr '[:upper:]' '[:lower:]' | grep -E 'id' | cut -d ':' -f 2 | tr -d '[:space:]')
            DIST_VERSION=$(lsb_release -a -u 2>&1 | tr '[:upper:]' '[:lower:]' | grep -E 'codename' | cut -d ':' -f 2 | tr -d '[:space:]')
        else
            if [ -r /etc/debian_version ] && [ "$LSB_DIST" != "ubuntu" ] && [ "$LSB_DIST" != "raspbian" ]; then
                if [ "$LSB_DIST" = "osmc" ]; then
                    # OSMC runs Raspbian
                    LSB_DIST=raspbian
                else
                    # We're Debian and don't even know it!
                    LSB_DIST=debian
                fi
                DIST_VERSION="$(sed 's/\/.*//' /etc/debian_version | sed 's/\..*//')"
                case "$DIST_VERSION" in
                    11)
                        DIST_VERSION="bullseye"
                    ;;
                    10)
                        DIST_VERSION="buster"
                    ;;
                    *)
                        echo "ERROR: your distribution's version ($DIST_VERSION) is either not recognized or not supported."
                        echo "Aborting."
                        exit 1
                    ;;
                esac
            fi
        fi
    fi

    echo "  Detected distribution:"
    printf "\t%s/%s\n" "$LSB_DIST" "$DIST_VERSION"
}

banner
check_dist_and_version
init "$@"
print_components
get_deps
add_repo
do_install_open
do_install_commercial
do_setup_mender
do_setup_addons
do_install_missing_monitor_dirs

exit 0
