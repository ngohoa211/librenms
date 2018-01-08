#!/usr/bin/env bash
################################################################################
# Copyright (C) 2015 Daniel Preussker, QuxLabs UG <preussker@quxlabs.com>
# Copyright (C) 2016 Layne "Gorian" Breitkreutz <Layne.Breitkreutz@thelenon.com>
# Copyright (C) 2017 Tony Murray <murraytony@gmail.com>
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
################################################################################

#######################################
# CONSTANTS
#######################################
# define DAILY_SCRIPT as the full path to this script and LIBRENMS_DIR as the directory this script is in
DAILY_SCRIPT=$(readlink -f "$0")
LIBRENMS_DIR=$(dirname "$DAILY_SCRIPT")
COMPOSER="php ${LIBRENMS_DIR}/scripts/composer_wrapper.php"

# set log_file, using librenms $config['log_dir'], if set
# otherwise we default to <LibreNMS Install Directory>/logs
LOG_DIR=$(php -r "@include '${LIBRENMS_DIR}/config.php'; echo isset(\$config['log_dir']) ? \$config['log_dir'] : '${LIBRENMS_DIR}/logs';")

# get the librenms user
LIBRENMS_USER=$(php -r "@include '${LIBRENMS_DIR}/config.php'; echo isset(\$config['user']) ? \$config['user'] : 'root';")
LIBRENMS_USER_ID=$(id -u "$LIBRENMS_USER")

#######################################
# Fancy-Print and run commands
# Globals:
#   LOG_DIR
# Arguments:
#   Text
#   Command
# Returns:
#   Exit-Code of Command
#######################################
status_run() {
    # Explicitly define our arguments
    local args="$@";
    local arg_text=$1;
    local arg_command=$2;
    local arg_option=$3;
    local log_file;
    local exit_code;
    local tmp;
    local log_file=${LOG_DIR}/daily.log;

    # set log_file, using librenms $config['log_dir'], if set
    # otherwise we default to ./logs/daily.log

    printf "%-50s" "${arg_text}";
    echo "${arg_text}" >> ${log_file}
    tmp=$(${arg_command} 2>&1);
    exit_code=$?
    echo "${tmp}" >> ${log_file}
    echo "Returned: ${exit_code}" >> ${log_file}

    # print OK if the command ran successfully
    # or FAIL otherwise (non-zero exit code)
    if [[ "${exit_code}" == "0" ]]; then
        printf " \033[0;32mOK\033[0m\n";
    else
        printf " \033[0;31mFAIL\033[0m\n";
        if [[ "${arg_option}" == "update" ]]; then
            php "${LIBRENMS_DIR}/daily.php" -f notify -o "${tmp}"
        fi
        if [[ ! -z "${tmp}" ]]; then
            # print output in case of failure
            echo "${tmp}"
        fi
    fi
    return ${exit_code}
}

#######################################
# Call daily.php
# Globals:
#   LIBRENMS_DIR
# Arguments:
#   args:
#        Array of arguments to pass to
#        daily.php
# Returns:
#   Exit-Code of Command
#######################################
call_daily_php() {
    local args=( "$@" );

    for arg in "${args[@]}"; do
        php "${LIBRENMS_DIR}/daily.php" -f "${arg}";
    done
}

#######################################
# Send result of a notifiable process to php code for processing
# Globals:
#   LIBRENMS_DIR
# Arguments:
#   args:
#        Type: update
#        Result: 1 for success, 0 for failure
# Returns:
#   Exit-Code of Command
#######################################
set_notifiable_result() {
    local args="$@";
    local arg_type=$1;
    local arg_result=$2;

    php "${LIBRENMS_DIR}/daily.php" -f handle_notifiable -t ${arg_type} -r ${arg_result};
}

#######################################
# Check the PHP version and branch and switch to the appropriate branch
# Returns:
#   Exit-Code: 0 >= min ver, 1 < min ver
#######################################
check_php_ver() {
    local branch=$(git rev-parse --abbrev-ref HEAD)
    local ver_res=$(php -r "echo (int)version_compare(PHP_VERSION, '5.6.4', '<');")
    if [[ "$branch" == "php53" && "$ver_res" == "0" ]]; then
        git checkout master
        branch="master"
    elif [[ "$branch" != "php53" && "$ver_res" == "1" ]]; then
        git checkout php53
        branch="php53"
    fi

    return ${ver_res};
}


#######################################
# Entry into program
# Globals:
#   LIBRENMS_DIR
# Arguments:
#
# Returns:
#   Exit-Code of Command
#######################################
main () {
    local arg="$1";
    local old_version="$2";
    local new_version="$3";
    local old_version="${old_version:=unset}"  # if $1 is unset, make it mismatch for pre-update daily.sh

    cd ${LIBRENMS_DIR};

    # if not running as $LIBRENMS_USER (unless $LIBRENMS_USER = root), relaunch
    if [[ "$LIBRENMS_USER" != "root" ]]; then
        # only try to su if we are root (or sudo)
        if [[ "$EUID" -eq 0 ]]; then
            echo "Re-running ${DAILY_SCRIPT} as ${LIBRENMS_USER} user"
            sudo -u "$LIBRENMS_USER" "$DAILY_SCRIPT" "$@"
            exit;
        fi

        if [[ "$EUID" -ne "$LIBRENMS_USER_ID" ]]; then
            printf "\033[0;93mWARNING\033[0m: You should run this script as ${LIBRENMS_USER}\n";
        fi
    fi

    # make sure autoload.php exists before trying to run any php that may require it
    if [ ! -f "${LIBRENMS_DIR}/vendor/autoload.php" ]; then
        ${COMPOSER} install --no-dev
    fi

    if [[ -z "$arg" ]]; then
        up=$(php daily.php -f update >&2; echo $?)
        if [[ "$up" == "0" ]]; then
            ${DAILY_SCRIPT} no-code-update
            set_notifiable_result update 1  # make sure there are no update notifications if update is disabled
            exit
        fi

        status_run 'Checking PHP version' 'check_php_ver'
        php_ver_ret=$?

        # make sure the vendor directory is clean
        git checkout vendor/ --quiet > /dev/null 2>&1

        update_res=0
        if [[ "$up" == "1" ]]; then
            # Update current branch to latest
            old_ver=$(git rev-parse --short HEAD)
            status_run 'Updating to latest codebase' 'git pull --quiet' 'update'
            update_res=$?
            new_ver=$(git rev-parse --short HEAD)
        elif [[ "$up" == "3" ]]; then
            # Update to last Tag
            old_ver=$(git describe --exact-match --tags $(git log -n1 --pretty='%h'))
            if [[ "$php_ver_ret" == "0" ]]; then
                status_run 'Updating to latest release' 'git fetch --tags && git checkout $(git describe --tags $(git rev-list --tags --max-count=1))' 'update'
                update_res=$?
            else
                # incompatible php version, check out last supported release
                status_run 'Updating to latest release' 'git fetch --tags && git checkout 1.35' 'update'
                update_res=$?
            fi
            new_ver=$(git describe --exact-match --tags $(git log -n1 --pretty='%h'))
        fi

        if (( $update_res > 0 )); then
            set_notifiable_result update 0
        fi

        # Call ourself again in case above pull changed or added something to daily.sh
        ${DAILY_SCRIPT} post-pull ${old_ver} ${new_ver}
    else
        case $arg in
            no-code-update)
                # Updates of the code are disabled, just check for schema updates
                # and clean up the db.
                status_run 'Updating SQL-Schema' 'php includes/sql-schema/update.php'
                status_run 'Cleaning up DB' "$DAILY_SCRIPT cleanup"
            ;;
            post-pull)
                # Check if we need to revert (Must be in post pull so we can update it)
                if [[ "$old_version" != "$new_version" ]]; then
                    check_php_ver # check php version and switch branches
                    php_res=$?
                    if [[ "$php_res" == "1" ]]; then
                        status_run "Reverting update, PHP version older than 5.6.4" ''
                    else
                        status_run "Updated from $old_version to $new_version" ''
                        set_notifiable_result update 1  # only clear the error if update was a success
                    fi
                fi

                # List all tasks to do after pull in the order of execution
                status_run 'Updating SQL-Schema' 'php includes/sql-schema/update.php'
                status_run 'Updating submodules' "$DAILY_SCRIPT submodules"
                status_run 'Cleaning up DB' "$DAILY_SCRIPT cleanup"
                status_run 'Fetching notifications' "$DAILY_SCRIPT notifications"
                status_run 'Caching PeeringDB data' "$DAILY_SCRIPT peeringdb"
            ;;
            cleanup)
                # Cleanups
                local options=("refresh_alert_rules"
                               "refresh_os_cache"
                               "syslog"
                               "eventlog"
                               "authlog"
                               "perf_times"
                               "callback"
                               "device_perf"
                               "purgeusers"
                               "bill_data"
                               "alert_log"
                               "rrd_purge");
                call_daily_php "${options[@]}";
            ;;
            submodules)
                # Init+Update our submodules
                git submodule --quiet init
                git submodule --quiet update
            ;;
            notifications)
                # Get notifications
                local options=("notifications");
                call_daily_php "${options[@]}";
            ;;
            peeringdb)
                local options=("peeringdb");
                call_daily_php "${options[@]}";
            ;;
        esac
    fi
}

main "$@"
