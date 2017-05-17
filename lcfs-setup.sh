#!/bin/bash

PATH="/opt/pwx/bin":${PATH}

if [ "$1" == "--debug" -o -n "${DEBUG}" ]; then
    DEBUG="yes" && set -x
    [ "$1" == "--debug" ] && shift
fi

ulimit -c unlimited

[ $(id -u) -ne 0 ] && SUDO=sudo

isAlpine=0
SYS_TYPE=$([ -e /etc/os-release ] && cat /etc/os-release | egrep '^ID=' | sed -e s'/^ID=//')
[ -n "${SYS_TYPE}" -a "${SYS_TYPE}" == "alpine" ] && isAlpine=1

isBusyBox=0
readlink -f $(which timeout) | egrep -q 'busybox$'
[ $? -eq 0 ] && isBusyBox=1

DOCKER_BIN=docker
DOCKER_SRV_BIN=dockerd
LCFS_ENV_DIR=/etc/lcfs
LCFS_ENV_FL=${LCFS_ENV_FL:-"${LCFS_ENV_DIR}/lcfs.env"}

[ -e "${LCFS_ENV_FL}" ] && source ${LCFS_ENV_FL}

if [ ${isAlpine} -eq 1 ]; then
    LCFS_PKG=${LCFS_PKG:-"http://lcfs.portworx.com/alpine/lcfs-alpine.binaries.tgz"}
else
    LCFS_PKG=${LCFS_PKG:-"http://lcfs.portworx.com/lcfs.rpm"}
fi
LCFS_IMG=${LCFS_IMG:-"portworx/lcfs:latest"}
DOCKER_MNT=${DOCKER_MNT:-"/var/lib/docker"}
PLUGIN_MNT=${PLUGIN_MNT:-"/lcfs"}
DEV=${DEV:-"/dev/sdNN"}
if [ ${isAlpine} -eq 1 ]; then
    DEVFL=${DEVFL:-"/var/lcfs-dev-file"}
    DSZ=${DSZ:-"2G"}
else
    DEVFL=${DEVFL:-"/lcfs-dev-file"}
    DSZ=${DSZ:-"500M"}
fi

# Linux DD is used create a device file for use by LCFS.  However if
# Large Files is not supported on the running filesystem then the max
# file size (DSZ) will be 2G. So DCOUNT may need to be updated to
# create device file larger than 2G.
DCOUNT=${DCOUNT:-"1"}

[ ${DCOUNT} -le 1 ] && DCOUNT=0         # Use sparse file allows for large files without DCOUNT

PWX_DIR=/opt/pwx

LCFS_BINARY=${PWX_DIR}/bin/lcfs

LOCAL_DNLD=${PWX_DIR}/dnld
if [ ${isAlpine} -eq 1 ]; then
    LOCAL_PKG=${LOCAL_PKG:-"${LOCAL_DNLD}/lcfs-alpine.binaries.tgz"}
else
    LOCAL_PKG=${LOCAL_DNLD}/lcfs.rpm
fi
LOCAL_MANIFEST=${LOCAL_DNLD}/manifest

DOCKER_DAEMON_CFG=/etc/docker/daemon.json

function cleanup_and_exit()
{
    [ "${DEBUG}" == "yes" ] && set +x
    exit $1
}

function clean_mount()
{
    local mnt=""

    [ -z "$1" ] && return 0
    # mountpoint -q "$1"
    # [ $? -eq 0 ] && ${SUDO} fusermount -q -u "$1" && sleep 3
    for mnt in $(cat /proc/mounts | awk '{print $2}' | egrep "^$1"); do ${SUDO} umount -f "${mnt}"; done
    return 0
}

function getPid()
{
    [ -z "$1" ] && echo ""

    local cmd="$1"
    local pid=""

    if [ ${isAlpine} -eq 1 ]; then
	pid=$(ps -o pid,comm  | egrep "${cmd}$" | awk '{print $1}' | egrep -v "^${PPID}$" | tr '\n' ' ')
    else
	pid=$(ps -C "$1" -o pid --no-header | tr '\n' ' ')
    fi

    echo ${pid}
}

function killprocess()
{
    local pid=$(getPid "$1")
    local topt=""

    [ -z "${pid}" ] && return 0
    for pd in ${pid}; do
	${SUDO} kill -s 15 ${pd} &> /dev/null
	[ ${isAlpine} -eq 1 -a ${isBusyBox} -eq 1 ] && topt="-t"
	${SUDO} timeout ${topt} 60 bash -c "while ${SUDO} kill -0 \"${pd}\"; do sleep 0.5; done" &> /dev/null
    done
    pid=$(getPid "$1")
    [ -n "${pid}" ] && echo "Failed to kill process for $1." && cleanup_and_exit 1
    return 0
}

function download_lcfs_binary()
{
    ${SUDO} mkdir -p ${LOCAL_DNLD}
    ${SUDO} curl --fail --netrc -s -o ${LOCAL_PKG} ${LCFS_PKG}
    [ $? -ne 0 ] && echo "Failed to download LCFS package ${LCFS_PKG}." && cleanup_and_exit 1
}

function install_lcfs_binary()
{
    local flg_fl=${PWX_DIR}/.lcfs

    if [ ${isAlpine} -eq 1 ]; then
	tar -C / -xzf ${LOCAL_PKG}
	[ $? -eq 0 ] && touch ${flg_fl}
    else
	[ -z "$(getPid ${DOCKER_SRV_BIN})" ] && dockerd_manual_start "${SUDO} ${DOCKER_SRV_BIN}"

	local centos_exists=$(${SUDO} ${DOCKER_BIN} images -q centos:latest)

	${SUDO} \rm -f ${flg_fl}
	${SUDO} ${DOCKER_BIN} run --rm --name centos -v /opt:/opt centos bash -c "rpm -qlp ${LOCAL_PKG} &> ${LOCAL_MANIFEST} && rpm -Uvh --nodeps ${LOCAL_PKG} && touch ${flg_fl}"
	[ -z "${centos_exists}" ] && ${SUDO} ${DOCKER_BIN} rmi centos:latest &> /dev/null
    fi
    [ ! -f ${flg_fl} ] && echo "Failed to install LCFS binaries." && cleanup_and_exit 1
    \rm -f ${flg_fl}
}

function install_fuse()
{
    [ ${isAlpine} -eq 1 ] && return 0

    ${SUDO} which fusermount &> /dev/null
    if [ $? -ne 0 ]; then
	local ltype=$(cat /proc/version | sed -e s'/(GCC) //' -e 's/.*(\(.*)\) ).*/\1/' -e 's/ [0-9].*$//' | tr -d ' ')

	case "${ltype,,}" in
            *redhat*)
		${SUDO} yum install --quiet -y fuse
		;;
	    *ubuntu*|*debian*)
		${SUDO} apt-get install -y fuse
		;;
            *)
		echo "Fuse fusermount is required please install fuse and try again."
		cleanup_and_exit 1
		;;
	esac
     fi
}

function remove_lcfs_plugin()
{
    ${SUDO} ${DOCKER_BIN} plugin ls | egrep -q "${LCFS_IMG}"
    [ $? -ne 0 ] && return 0
    ${SUDO} ${DOCKER_BIN} plugin disable ${LCFS_IMG} &> /dev/null
    ${SUDO} ${DOCKER_BIN} plugin rm ${LCFS_IMG} &> /dev/null
}

function backup_docker_cfg()
{
    if [ -e "${DOCKER_DAEMON_CFG}" ]; then
	echo "Backing up existing docker configuration: ${DOCKER_DAEMON_CFG}..."
	${SUDO} mv -f ${DOCKER_DAEMON_CFG} ${DOCKER_DAEMON_CFG}.bak
	echo "Backup made: ${DOCKER_DAEMON_CFG}.bak"
    fi
}

function restore_docker_cfg()
{
    if [ -e "${DOCKER_DAEMON_CFG}" -a -e "${DOCKER_DAEMON_CFG}.bak" ]; then
	echo "Warning: New docker configuration exists while trying restoring the original one."
	echo "Backing up new configuration to restore the original: ${DOCKER_DAEMON_CFG}..."
	${SUDO} mv -f ${DOCKER_DAEMON_CFG} ${DOCKER_DAEMON_CFG}.new.bak
	echo "Backup made: ${DOCKER_DAEMON_CFG}.new.bak"
    fi

    if [ -e "${DOCKER_DAEMON_CFG}.bak" ]; then
	echo "Restoring original docker configuration backup..."
	${SUDO} mv /etc/docker/daemon.json.bak /etc/docker/daemon.json
	echo "Done restoring: ${DOCKER_DAEMON_CFG}."
	if [ -e "${DOCKER_DAEMON_CFG}.new.bak" ]; then
	    echo "NOTE: Manual merge of configuration files: ${DOCKER_DAEMON_CFG} and ${DOCKER_DAEMON_CFG}.new.bak is needed."
	fi
    fi
}

function dockerd_manual_start()
{
    local dcmd=($1)
    local out_fl=/tmp/ldocker.out.$$
    local topt=""

    [ -d "/var/run/docker.sock" ] && rmdir "/var/run/docker.sock"
    ${dcmd[@]} >> ${out_fl} 2>&1 &
    sleep 2   # Allow time for docker to start
    local status=1
    if [ -n "$(getPid ${DOCKER_SRV_BIN})" ]; then
	# allow 5 mins for docker to come up even with plugins.
	[ ${isAlpine} -eq 1 -a ${isBusyBox} -eq 1 ] && topt="-t"
	${SUDO} timeout ${topt} 300 bash -c "while [ ! -e ${out_fl} ] || ! (tail -n 5 ${out_fl} | egrep -q 'listen on .*docker.sock\".*$'); do echo 'checking docker start...' ; sleep 1; done"
	status=$?
    fi
    [ ${status} -ne 0 ] && echo "Error: failed to start docker." && cat ${out_fl}
    ${SUDO} \rm ${out_fl}
    if [ ${status} -ne 0 ]; then
	STOP="--stop" && stop_remove_lcfs 1
    fi
}


function system_docker_stop()
{
    local sysd_pid=$(getPid systemd)
    local sysV_docker="/etc/init.d/docker"

    if [ -z "${START}" -a -z "${STOP}" -a -z "${REMOVE}" ]; then
	[ -n "${sysd_pid}" ] && ${SUDO} systemctl stop docker          # Systemd stop
	[ -e "${sysV_docker}" ] && ${SUDO} /etc/init.d/docker stop; # SystemV stop
    fi
    killprocess ${DOCKER_SRV_BIN};                              # last resort
}

function system_docker_restart()
{
    local sysd_pid=$(getPid systemd)
    local sysV_docker="/etc/init.d/docker"

    if [ -n "${sysd_pid}" ]; then
        ${SUDO} systemctl restart docker     # Systemd restart
    elif [ -e "${sysV_docker}" ]; then
        ${SUDO} /etc/init.d/docker restart;  # SystemV restart
    fi
}

function system_manage()
{
    [ -z "$1" -o -z "$2" ] && echo "Warning: System manage setting failed." && return 1

    local sysd_pid=$(getPid systemd)
    local sysV="/etc/init.d/$2"

    echo "$1 $2..."
    [ -n "${sysd_pid}" ] && ${SUDO} systemctl $1 $2       # Systemd Manage

    if [ -e "${sysV}" ]; then                             # SystemV Manage
	case $1 in
            enable)
		if [ -n "$(${SUDO} which chkconfig)" ]; then
		    ${SUDO} chkconfig $2 on
		elif [ -n "$(${SUDO} which rc-update)" ]; then
		    ${SUDO} rc-update add $2
		fi
		;;
	    disable)
		if [ -n "$(${SUDO} which chkconfig)" ]; then
		    ${SUDO} chkconfig $2 off
		elif [ -n "$(${SUDO} which rc-update)" ]; then
		    ${SUDO} rc-update del $2
		fi
		;;
            *)
		${SUDO} ${sysV} $1
		;;
	esac

    fi
}

function lcfs_docker_startup_setup()
{
    local sysd_pid=$(getPid systemd)

    echo "Setup LCFS Docker startup..."
    if [ -n "${sysd_pid}" ]; then   # Systemd setup
	[ -e /etc/systemd/system/docker.service -a ! -e /etc/systemd/system/docker.service.orig ] && ${SUDO} cp -a /etc/systemd/system/docker.service /etc/systemd/system/docker.service.orig
	${SUDO} cp -a /opt/pwx/services/lcfs.systemctl /etc/systemd/system/docker.service
	${SUDO} systemctl daemon-reexec  # Re-exec systemd bug (http://superuser.com/questions/1125250/systemctl-access-denied-when-root).
	${SUDO} systemctl reenable docker
    elif [ -d /etc/init.d ]; then   # SystemV setup
	[ -e /etc/init.d/docker -a ! -e /etc/init.d/docker.orig ] && ${SUDO} cp -a /etc/init.d/docker /etc/init.d/docker.orig
	${SUDO} cp -a /opt/pwx/services/lcfs.systemv /etc/init.d/docker && ${SUDO} chkconfig docker on
    fi

    [ $? -ne 0 ] && echo "Warning: LCFS Docker startup configuration failed. LCFS Docker will not start automatically on system reboot."

    return 0
}

function lcfs_docker_startup_remove()
{
    local sysd_pid=$(getPid systemd)

    if [ -n "${sysd_pid}" ]; then   # Systemd setup
	${SUDO} systemctl disable docker &> /dev/null
	if [ -e /etc/systemd/system/docker.service.orig ]; then
	    ${SUDO} mv -f /etc/systemd/system/docker.service.orig /etc/systemd/system/docker.service
	else
	    ${SUDO} rm -f /etc/systemd/system/docker.service
	fi
	${SUDO} systemctl daemon-reexec  # Re-exec systemd bug (http://superuser.com/questions/1125250/systemctl-access-denied-when-root).
    elif [ -d /etc/init.d ]; then   # SystemV setup
	${SUDO} chkconfig docker off &> /dev/null
	if [ -e /etc/init.d/docker.orig ]; then
	    ${SUDO} mv -f /etc/init.d/docker.orig /etc/init.d/docker
	fi
    fi
}

function lcfs_startup_setup()
{
    local sysd_pid=$(getPid systemd)

    echo "Setup LCFS startup..."
    if [ -n "${sysd_pid}" ]; then   # Systemd setup
	${SUDO} cp -a /opt/pwx/services/lcfs.systemctl /etc/systemd/system/lcfs.service
	${SUDO} systemctl daemon-reexec  # Re-exec systemd bug (http://superuser.com/questions/1125250/systemctl-access-denied-when-root).
	${SUDO} systemctl enable lcfs
    elif [ -d /etc/init.d ]; then   # SystemV setup
	${SUDO} cp -a /opt/pwx/services/lcfs.systemv /etc/init.d/lcfs
	if [ -n "$(${SUDO} which chkconfig)" ]; then
	    ${SUDO} chkconfig lcfs on
	elif [ -n "$(${SUDO} which rc-update)" ]; then
	    ${SUDO} rc-update add lcfs
	fi
    fi

    [ $? -ne 0 ] && echo "Warning: LCFS startup configuration failed. LCFS will not start automatically on system reboot."

    return 0
}

function lcfs_startup_remove()
{
    local sysd_pid=$(getPid systemd)

    if [ -n "${sysd_pid}" ]; then   # Systemd setup
	${SUDO} systemctl disable lcfs &> /dev/null
	${SUDO} rm -f /etc/systemd/system/lcfs.service
    elif [ -d /etc/init.d ]; then   # SystemV setup
	if [ -n "$(${SUDO} which chkconfig)" ]; then
	    ${SUDO} chkconfig lcfs off &> /dev/null
	elif [ -n "$(${SUDO} which rc-update)" ]; then
	    ${SUDO} rc-update del lcfs
	fi
	${SUDO} rm /etc/init.d/lcfs
    fi
}

function isDockerService()
{
    local sysd_pid=$(getPid systemd)
    local docker_service=""

    if [ -n "${sysd_pid}" ]; then   # Systemd setup
	if [ -e /etc/systemd/system/docker.service ]; then
	    cat /etc/systemd/system/docker.service | egrep -q '^ExecStart=.*lcfs-setup.sh'
	    [ $? -eq 0 ] && docker_service="yes"
	fi
    elif [ -d /etc/init.d ]; then   # SystemV setup
	if [ -e /etc/init.d/docker ]; then
	    cat /etc/init.d/docker | egrep -q '^SERVICE_SCRIPT=.*lcfs-setup.sh'
	    [ $? -eq 0 ] && docker_service="yes"
	fi
    fi

    [ -n "${docker_service}" ]
}

function startup_setup()
{
    if [ -n "${DOCKER_SERVICE}" ]; then
	lcfs_docker_startup_setup
	system_manage "start" "docker"   # Restart LCFS Docker using system management (systemclt/SystemV)
    else
	lcfs_startup_setup
	system_manage "start" "lcfs"   # Restart LCFS using system management (systemclt/SystemV)
    fi
}

function startup_remove()
{
    isDockerService
    if [ $? -eq 0 ]; then
	lcfs_docker_startup_remove
    else
	lcfs_startup_remove
    fi
}

function lcfs_configure_save()
{
    local tmp_cfg=/tmp/.lcfs.env

    echo 'LCFS_PKG=${LCFS_PKG:-"'${LCFS_PKG}'"}' > ${tmp_cfg}
    echo 'LCFS_IMG=${LCFS_IMG:-"'${LCFS_IMG}'"}' >> ${tmp_cfg}
    echo 'DOCKER_MNT=${DOCKER_MNT:-"'${DOCKER_MNT}'"}' >> ${tmp_cfg}
    echo 'PLUGIN_MNT=${PLUGIN_MNT:-"'${PLUGIN_MNT}'"}' >> ${tmp_cfg}
    echo 'DEVFL=${DEVFL:-"'${DEVFL}'"}' >> ${tmp_cfg}
    echo 'DEV=${DEV:-"'${DEV}'"}' >> ${tmp_cfg}
    echo 'DSZ=${DSZ:-"'${DSZ}'"}' >> ${tmp_cfg}
    echo 'DCOUNT=${DCOUNT:-"'${DCOUNT}'"}' >> ${tmp_cfg}

    ${SUDO} mkdir -p ${LCFS_ENV_DIR}
    ${SUDO} \mv ${tmp_cfg} ${LCFS_ENV_FL}
    ${SUDO} \rm -f /etc/pwx/lcfs.env        # Remove old configuration if it exists.
}

function lcfs_configure()
{
    local limg dmnt lmnt ldev lsz ploc dyn
    local sz_msg="${DSZ}" sparse="sparse "

    read -p "LCFS install package (full filename|URL) [${LCFS_PKG}]: " ploc
    [ -n "${ploc}" ] && LCFS_PKG="${ploc}"

    read -p "LCFS docker plugin [${LCFS_IMG}]: " limg
    [ -n "${limg}" ] && LCFS_IMG="${limg}"

    read -p "LCFS device or file [${DEV}]: " ldev
    [ -z "${ldev}" ] && ldev="${DEV}"

    if [ ! -e "${ldev}" ]; then
	read -p  "LCFS device/file does not exist. Create file (y/n)? " dyn
        if [ "${dyn,,}" = "y" ]; then
	    [ "${DEV}" == "/dev/sdNN" ] && ldev=${DEVFL}
	    [ ${DCOUNT} -gt 1 ] && sz_msg="${sz_msg} * ${DCOUNT}" && sparse=""
	    read -p "LCFS ${sparse}file: ${ldev} size [${sz_msg}]: " lsz
	    [ -z "${lsz}" ] && lsz="${DSZ}"
	    if [ ${DCOUNT} -gt 1 ]; then
		${SUDO} dd if=/dev/zero of=${ldev} count=${DCOUNT} bs=${lsz} &> /dev/null
	    else
		${SUDO} dd if=/dev/zero of=${ldev} count=${DCOUNT} bs=1 seek=${lsz} &> /dev/null
	    fi
	    [ $? -ne 0 ] && echo "Error: Failed to create LCFS device file ${ldev}." && cleanup_and_exit 0
#	    DEVFL="${ldev}"
	    DSZ="${lsz}"
	else
	    echo "LCFS device or file required." && cleanup_and_exit 0
        fi
    fi
    [ -n "${ldev}" ] && DEV="${ldev}"
    [ -f "${ldev}" ] && DEVFL="${ldev}"

    read -p "LCFS mount point [${PLUGIN_MNT}]: " lmnt
    [ -n "${lmnt}" ] && PLUGIN_MNT="${lmnt}"

    read -p "Docker mount point [${DOCKER_MNT}]: " dmnt
    [ -n "${dmnt}" ] && DOCKER_MNT="${dmnt}"

    echo "Saving LCFS configuration...."
    lcfs_configure_save
}

function stop_remove_lcfs
{
    local rcode=$1

    system_docker_stop

    # Stop docker && cleanup
    clean_mount "${DOCKER_MNT}/plugins"
    clean_mount "${PLUGIN_MNT}"
    clean_mount "${DOCKER_MNT}"
    killprocess lcfs
    sleep 3

    if [ -n "${REMOVE}" ]; then
	dockerd_manual_start "${SUDO} ${DOCKER_SRV_BIN} -s vfs"
	remove_lcfs_plugin
	killprocess ${DOCKER_SRV_BIN}
	[ "${DEV}" != "/dev/sdNN" -a -z "${ZERODEV}" ] && read -p "Clear (dd) or remove the lcfs device or file [${DEV}] (y/n)? " yn
	if [ "${yn,,}" = "y" -o -n "${ZERODEV}"  ]; then
	    [ "${DEV}" != "/dev/sdNN" ] && ${SUDO} dd if=/dev/zero of=${DEV} count=1 bs=4096 &> /dev/null
	    ${SUDO} \rm -f ${DEVFL}
	fi

	[ -e ${LCFS_ENV_FL} ] && ${SUDO} \mv -f ${LCFS_ENV_FL} ${LCFS_ENV_FL}.save
	${SUDO} \rm -f /etc/pwx/lcfs.env    # Remove old configuration if it exists.

	startup_remove
	restore_docker_cfg
	system_docker_restart
	system_manage "enable" "docker"   # Reenable docker startup.
    fi
    [ -z "${rcode}" ] && rcode=0
    [ -n "${STOP}" -o -n "${REMOVE}" ] && cleanup_and_exit ${rcode}

    return 0
}

function status_lcfs()
{
    local lpid="" lcmd="" ldev="" ldmnt="" lpmnt="" lstatus=0
    local ldpid="" lfcmd="" dstatus

    if [ ${isAlpine} -eq 1 ]; then
	lpid=$(getPid lcfs)
	[ -n "${lpid}" ] && read lpid lcmd lmode ldev ldmnt lpmnt<<<$(ps -o pid,args  | egrep "^ *${lpid} " | tr '\n' ' ')
    else
	read lpid lcmd lmode ldev ldmnt lpmnt<<<$(ps -C lcfs -o pid,command --no-header)
    fi
    lstatus=$?

    if [ ${isAlpine} -eq 1 ]; then
	ldpid=$(getPid ${DOCKER_SRV_BIN})
	[ -n "${ldpid}" ] && read ldpid lfcmd<<<$(ps -o pid,args  | egrep "^ *${ldpid} " | tr '\n' ' ')
    else
	read ldpid lfcmd<<<$(ps -C ${DOCKER_SRV_BIN} -o pid,command --no-header)
    fi
    dstatus=$?

    if [ ${lstatus} -eq 0 -a -n "${lpid}" ]; then
	echo "LCFS (pid ${lpid}) is running..."
	echo "LCFS device or file: ${ldev}"
	echo "LCFS docker mnt: ${ldmnt}"
	echo "LCFS plugin mnt: ${lpmnt}"
    else
	echo "LCFS is stopped."
	lstatus=1
    fi

    if [ ${dstatus} -eq 0 -a -n "${ldpid}" ]; then
	echo "Docker (pid ${ldpid}) is running..."
	echo "Docker command: $lfcmd"
    else
	echo "Docker is stopped."
	dstatus=1
    fi

    cleanup_and_exit $((lstatus+${dstatus}));
}

function version_lcfs()
{
    [ ! -e "${LCFS_BINARY}" ] && echo "LCFS is not installed." && cleanup_and_exit 0

    ${SUDO} strings "${LCFS_BINARY}" | egrep '^(Release|Build):'
    cleanup_and_exit $?
}

function help()
{
    echo "Usage: $0 [--help] [--configure] [--start] [--stop] [--status] [--stop-docker] [--remove]"
    echo -e "\t--configure: \tCreate and use configuration file."
    echo -e "\t--start: \tStart docker and lcfs."
    echo -e "\t--stop: \tStop docker and lcfs."
    echo -e "\t--status: \tStatus docker and lcfs."
    echo -e "\t--remove: \tStop and remove lcfs."
    echo -e "\t--version: \tDisplay LCFS version."
    echo -e "\t--help: \tDisplay this message."
    cleanup_and_exit $?
}

function docker_version_check()
{
    [ "${_LCFS_SKIP_VERSION_CHECK_}" == "yes" ] && return 0

    ${SUDO} docker version --format '{{.Server.Version}}' &> /dev/null
    [ $? -ne 0 ] && echo "Error: failed to check docker version. ${errmsg} Verify docker is running." && cleanup_and_exit 1

    local errmsg="Docker 1.13 or greater is required to run LCFS."
    local dversion=$(${SUDO} docker version --format '{{.Server.Version}}')

    if [ $(echo "${dversion}" | awk -F'.' '{printf "%s%s",$1,$2}') -lt 113 ]; then
	echo "Invalid Docker Version. ${errmsg}" && cleanup_and_exit 1
    fi

    return 0
}

DOCKER_SERVICE=""      # Unset docker service marker variable.

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    [ "${args[i]}" == "--configure" ] && docker_version_check
    [ "${args[i]}" == "--remove" ] && _LCFS_SKIP_VERSION_CHECK_="yes"
done

[ -z "$1" -o ! -e "${LCFS_ENV_FL}" ] && docker_version_check

while [ "$1" != "" ]; do
    case $1 in
        -h |--help)
            help
            ;;
        --start)
	    START="$1"
            ;;
        --stop)
	    STOP="$1"
	    stop_remove_lcfs
            ;;
	--status)
	    status_lcfs
	    ;;
        --remove)
	    isDockerService
	    [ $? -ne 0 ] && system_manage "stop" "lcfs" || system_manage "stop" "docker"
	    REMOVE="$1"
	    stop_remove_lcfs
            ;;
        --stop-docker)
	    system_docker_stop
            ;;
	--configure)
	    lcfs_configure
            ;;
	--version)
	    version_lcfs
            ;;
        --docker-service)
	    DOCKER_SERVICE="yes"
            ;;
        *)
            echo "Error: invalid input parameter."
            help
            ;;
    esac
    shift
done

# Install lcfs binary
if [ -z "${START}" ]; then
    install_fuse
    download_lcfs_binary
    install_lcfs_binary
elif [ ! -e "${LCFS_ENV_FL}" ]; then # --start was executed. Check config
    echo "LCFS not configured.  Re-execute this command with no options for a default configuration or with the '--configure' option."
    cleanup_and_exit 1
fi

stop_remove_lcfs  # Stop existing docker if setup or --configure.

# * Setup LCFS and start *

if [ ! -e "${DEV}" ]; then
    sz_msg="${DSZ}"
    sparse="sparse "

    [ ${DCOUNT} -gt 1 ] && sz_msg="${sz_msg} * ${DCOUNT}" && sparse=""
    echo "LCFS device: ${DEV} not found.  Creating ${sparse}device file: ${DEVFL} ${sz_msg}."
    if [ ${DCOUNT} -gt 1 ]; then
	${SUDO} dd if=/dev/zero of=${DEVFL} count=${DCOUNT} bs=${DSZ}
    else
	${SUDO} dd if=/dev/zero of=${DEVFL} count=${DCOUNT} bs=1 seek=${DSZ}
    fi
    [ $? -ne 0 ] && echo "Error: Failed to create LCFS device file ${ldev}." && cleanup_and_exit 0
    DEV=${DEVFL}
else
    echo "Note: LCFS device file exists. Using existing device file ${DEV} without modifying."
fi

sleep 5   #  Allow time for unmounts to happen.

${SUDO} mkdir -p ${PLUGIN_MNT} ${DOCKER_MNT}

# Mount lcfs
${SUDO} ${LCFS_BINARY} daemon ${DEV} ${DOCKER_MNT} ${PLUGIN_MNT}
LSTATUS=$?
sleep 3
[ -z "$(getPid lcfs)" -o ${LSTATUS} -ne 0 ] && echo "Failed to start LCFS binary [${LSTATUS}]." && cleanup_and_exit ${LSTATUS}

backup_docker_cfg

# Restart docker
if [ -z "${START}" ]; then
    dockerd_manual_start "${SUDO} ${DOCKER_SRV_BIN} -s vfs"
    if [ $? -eq 0 ]; then
	remove_lcfs_plugin
	${SUDO} ${DOCKER_BIN} plugin install --grant-all-permissions ${LCFS_IMG}
    fi
    killprocess ${DOCKER_SRV_BIN}
fi

dockerd_manual_start "${SUDO} ${DOCKER_SRV_BIN} --experimental -s ${LCFS_IMG}"
${SUDO} ${DOCKER_BIN} info
if [ -z "${START}" ]; then
    lcfs_configure_save
    if [ $? -ne 0 ]; then
	echo "Error: LCFS save configuration failed. Setup failed." && REMOVE=yes && stop_remove_lcfs 1  # exit(1)
    fi

    system_manage "disable" "docker"   # Disable docker startup for now if LCFS is setup.
    if [ $? -eq 0 ]; then
	stop_remove_lcfs
	startup_setup
    fi
fi
cleanup_and_exit $?
