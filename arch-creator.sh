#!/bin/bash

DEFAULT_IMAGE="${SALT_PREFIX:-"archlinux"}"
SALT_ENV="${SALT_ENV:-"base"}"
PILLAR_ENV="${PILLAR_ENV:-"base"}"
SALT_MASTER="${SALT_MASTER:-"salt.pie.cri.epita.fr"}"
ANNOUNCE_URL="http://torrent.pie.cri.epita.fr:8000/announce"
WEBSEED_URL="https://ipxe.pie.cri.epita.fr/cri-pxe-images.s3.cri.epita.fr/"

MKSQUASHFS_OPTIONS="-comp xz"
MKSQUASHFS_OPTIONS_DEBUG="-comp gzip -noI -noD -noF -noX"

IMAGES_DIR="imgs"
WORK_DIR="tmp"

###############################
# DO NOT EDIT BELOW THIS LINE #
###############################

DEBUG=false
IGNORE_FAILURES=false
KEEP_OUTPUT=false
RUN_CMD="sh -c"
RUN_LABEL="run"

E="\033"
C_RESET="$E[0m"
C_RED="$E[31m"
C_GREEN="$E[32m"
C_YELLOW="$E[33m"
C_MAGENTA="$E[35m"
C_CYAN="$E[36m"

usage() {
	echo "Usage: $0 -h|--help"
	echo "Usage: $0 build [-d|--debug] [-i|--ignore-failures] [-e SALT_ENV] [-m SALT_MASTER] IMAGE_NAME"
	echo "Usage: $0 torrent [-t|--tracker ANNOUNCE_URL] [*|IMAGE_NAME...]"
	echo "Usage: $0 clean [*|IMAGE_NAME...]"
}

info() {
	printf "${PREFIX}\033[32m*${C_RESET} %s\n" "$*"
}

run_unless() {
	COND="$1"
	shift
	printf "${PREFIX}${C_CYAN}->${C_RESET} ${RUN_LABEL} [%s]... " "$*"
	if eval ${COND}; then
		printf "${C_YELLOW}[SKIPPED]${C_RESET}\n"
	else
		if $KEEP_OUTPUT || $DEBUG; then
			printf "\n    ${PREFIX}${C_MAGENTA}-- START OF OUTPUT --${C_RESET}\n"
			if ! ${RUN_CMD} "$*"; then
				printf "\n    ${PREFIX}${C_MAGENTA}--  END OF OUTPUT  -- ${C_RESET}"
				printf "${C_RED}[FAILURE]${C_RESET}\n"
				if ! ${IGNORE_FAILURES}; then
					exit 1
				fi
			fi
			printf "${PREFIX}    ${C_MAGENTA}--  END OF OUTPUT  -- ${C_RESET}"
		else
			if ! ${RUN_CMD} "$*" > /dev/null; then
				printf "${C_RED}[FAILURE]${C_RESET}\n"
				printf "${C_RED}[FAILURE]${C_RESET}\n"
				if ! ${IGNORE_FAILURES}; then
					exit 1
				fi
			fi
		fi
		printf "${C_GREEN}[SUCCESS]${C_RESET}\n"
	fi
}

run() {
	run_unless "false" "$@"
}

run_chroot_unless() {
	RUN_CMD="arch-chroot "${ROOTFS_DIR}" /bin/sh -c"
	RUN_LABEL="run_chroot"
	run_unless "$@"
	RUN_CMD="/bin/sh -c"
	RUN_LABEL="run"
}

run_chroot() {
	run_chroot_unless "false" "$@"
}

step() {
	info "$*..."
	PREFIX="${PREFIX}    "
}

unstep() {
	PREFIX="${PREFIX:4}"
}

run_mkdir() {
	run_unless "[ -d '$1' ]" mkdir -p "$1"
}

create_dirs(){
	step "Creating directories"

	run_mkdir "${IMAGES_DIR}"
	run_mkdir "${ROOTFS_DIR}"

	unstep
}

bootstrap() {
	step "Bootstraping Archlinux"

	run_unless '[ -d "${ROOTFS_DIR}/bin" ]' "pacman -Qgq base base-devel" \
		"| grep -v '^linux' | sort -u | xargs" \
		"pacstrap -cd ${ROOTFS_DIR}"

	run "cp /usr/lib/locale/locale-archive ${ROOTFS_DIR}/usr/lib/locale/locale-archive"

	unstep
}

install_salt() {
	step "Installing and configuring salt minion"

	run_chroot_unless '[ -f "${ROOTFS_DIR}/usr/bin/salt" ]' \
		"pacman -Sy --noconfirm salt"

	tmpfile=`mktemp`
	grep -Ev '^master:' "${ROOTFS_DIR}/etc/salt/minion" > "${tmpfile}"
	cat ${tmpfile} > "${ROOTFS_DIR}/etc/salt/minion"
	echo "master: ${SALT_MASTER}" >> "${ROOTFS_DIR}/etc/salt/minion"
	rm "${tmpfile}"

	if ! grep "service: systemd" "${ROOTFS_DIR}/etc/salt/minion" > /dev/null 2>&1; then
		echo "providers:" >> "${ROOTFS_DIR}/etc/salt/minion"
		echo "  service: systemd" >> "${ROOTFS_DIR}/etc/salt/minion"
		echo "systemd.scope: False" >> "${ROOTFS_DIR}/etc/salt/minion"
	fi

	run_mkdir "${ROOTFS_DIR}/var/log/salt"
	run_mkdir "${ROOTFS_DIR}/etc/salt/pki/minion"

	unstep
}

call_salt() {
	step "Calling salt"

	# Salt is broken with current version of systemd
	run_unless '[ -f "${ROOTFS_DIR}/bin/systemctl.old" ]' \
		cp "${ROOTFS_DIR}/bin/systemctl" "${ROOTFS_DIR}/bin/systemctl.old"
	run cp "files/systemctl-wrapper" "${ROOTFS_DIR}/bin/systemctl"

	KEEP_OUTPUT=true
	run_chroot "salt-call --retcode-passthrough" \
		"--id ${IMAGE_NAME}-arch_creator state.highstate" \
		"saltenv=${SALT_ENV} pillarenv=${PILLAR_ENV}"
	KEEP_OUTPUT=false

	unstep
}

conf() {
	step "Configuring ${IMAGE_NAME}"
	run ln -sf "/usr/lib/systemd/resolv.conf" \
		"${ROOTFS_DIR}/etc/resolv.conf"
	unstep
}

gen_kernel() {
	step "Generating kernel & initramfs"


	run_chroot "mv /bin/systemctl.old /bin/systemctl"

	run_chroot "pacman -Sy --noconfirm --needed linux-lts linux-lts-headers git asciidoc dhclient cpio xz rng-tools iputils"
	kver=$(cd "${ROOTFS_DIR}/lib/modules/"; echo [0-9]*.*-lts)

	# arping is broken with current version of iputils
	ARPING_PKG="iputils-20180629.f6aac8d-4-x86_64.pkg.tar.xz"
	run cp "files/${ARPING_PKG}" "${ROOTFS_DIR}/root"
	run_chroot "pacman -U --noconfirm /root/${ARPING_PKG}"

	run_chroot_unless '[ -d "${ROOTFS_DIR}/root/dracut" ]' "git clone https://github.com/epita/dracut.git /root/dracut"
	run cp "files/dracut-cri.conf" "${ROOTFS_DIR}/root/dracut/dracut-cri.conf"
	run_chroot "cd /root/dracut; ./configure; make"
	run_chroot "cd /root/dracut; ./dracut.sh -l --force --conf dracut-cri.conf /root/initramfs-linux.img ${kver} --install rngd"

	run cp "${ROOTFS_DIR}/boot/vmlinuz-linux-lts" \
		"${IMAGES_DIR}/${IMAGE_NAME}_vmlinuz-linux"
	run cp "${ROOTFS_DIR}/root/initramfs-linux.img" \
		"${IMAGES_DIR}/${IMAGE_NAME}_initramfs-linux.img"

	chmod +r "${IMAGES_DIR}/${IMAGE_NAME}_initramfs-linux.img"

	run_chroot "rm /root/initramfs-linux.img"

	# Salt is broken with current version of systemd
	run_unless '[ -f "${ROOTFS_DIR}/bin/systemctl.old" ]' \
		cp "${ROOTFS_DIR}/bin/systemctl" "${ROOTFS_DIR}/bin/systemctl.old"
	run cp "files/systemctl-wrapper" "${ROOTFS_DIR}/bin/systemctl"

	unstep
}

clean_fs() {
	step "Cleaning filesystem"

	run find "${ROOTFS_DIR}/boot" -type f -name '*.img' -delete
	run find "${ROOTFS_DIR}/boot" -type f -name 'vmlinuz' -delete
	run find "${ROOTFS_DIR}/var/lib/pacman" -maxdepth 1 -type f -delete
	run find "${ROOTFS_DIR}/var/lib/pacman/sync" -delete
	run find "${ROOTFS_DIR}/var/cache/pacman/pkg" -type f -delete
	run rm -rf "${ROOTFS_DIR}/root/dracut"

	run echo > "${ROOTFS_DIR}/etc/machine-id"
	run rm -f "${ROOTFS_DIR}/var/lib/dbus/machine-id"

	unstep
}

squashfs() {
	step "Creating squashfs"

	run_unless '[ ! -f ${IMAGE_FILE} ]' rm -f "${IMAGE_FILE}"
	KEEP_OUTPUT=true
	run mksquashfs "${ROOTFS_DIR}" "${IMAGE_FILE}" ${MKSQUASHFS_OPTIONS}
	KEEP_OUTPUT=false

	unstep
}

# arch-chroot does not create a mount point for / by default so the root
# directory must be already mounted before chrooting in
mount_bind() {
	step "Mounting ROOTFS"
	mount --bind ${ROOTFS_DIR} ${ROOTFS_DIR}
	unstep
}

umount_bind() {
	step "Unmounting ROOTFS"
	umount ${ROOTFS_DIR}
	unstep
}

build() {
	IMAGE_NAME=${1:-"${DEFAULT_IMAGE}"}
	ROOTFS_DIR="${WORK_DIR}/${IMAGE_NAME}/rootfs"
	IMAGE_FILE="${IMAGES_DIR}/${IMAGE_NAME}.squashfs"

	if [[ $EUID -ne 0 ]]; then
	   printf "${C_RED}$0: The build command can only be run as root.${C_RESET}\n" 1>&2
	   exit 1
	fi

	step "Building ${IMAGE_NAME}..."

	create_dirs
	mount_bind
	bootstrap
	install_salt
	conf
	call_salt
	gen_kernel
	clean_fs
	squashfs

	unstep
}

clean() {
	IMAGE_NAME=${1:-"*"}
	ROOTFS_DIR="${WORK_DIR}/${IMAGE_NAME}/rootfs"

	if [[ $EUID -ne 0 ]]; then
	   printf "${C_YELLOW}$0: You may need to run the clean command as root to remove some files.${C_YELLOW}\n" 1>&2
	fi

	step "Cleaning ${IMAGE_NAME}"

	umount_bind
	run rm -rf `dirname "${ROOTFS_DIR}"`
	run rm -rf "${IMAGES_DIR}/${IMAGE_NAME}.squashfs"
	run rm -rf "${IMAGES_DIR}/${IMAGE_NAME}_*"

	unstep
}

torrent() {
	IMAGE_NAME=${1:-"*"}
	IMAGE_FILE="${IMAGES_DIR}/${IMAGE_NAME}.squashfs"

	step "Generating torrent files"

	cd ${IMAGES_DIR}
	for file in `find -name "${IMAGE_NAME}.squashfs"`; do
		torrent="${file%.squashfs}.torrent"
		run_unless "[ ! -f '${torrent}' ]" rm "${torrent}"
		run mktorrent -a "${ANNOUNCE_URL}" -w "${WEBSEED_URL} " \
			-o "${torrent}" "${file}"
	done

	unstep
}

genkernel() {
	IMAGE_NAME=${1:-"${DEFAULT_IMAGE}"}
	ROOTFS_DIR="${WORK_DIR}/${IMAGE_NAME}/rootfs"
	IMAGE_FILE="${IMAGES_DIR}/${IMAGE_NAME}.squashfs"

	if [[ $EUID -ne 0 ]]; then
	   printf "${C_RED}$0: The build command can only be run as root.${C_RESET}\n" 1>&2
	   exit 1
	fi

	step "Generating kernel and initramfs"

	create_dirs
	mount_bind
	bootstrap
	gen_kernel

	unstep
}

GO_SHORT="hide:m:t:"
GO_LONG="help,ignore-failures,debug,environment,master:,tracker:"

GO_PARSED=$(getopt --options ${GO_SHORT} --longoptions ${GO_LONG} \
            --name "$0" -- "$@")

if [[ $? -ne 0 ]]; then
	usage
	exit 2
fi

eval set -- "${GO_PARSED}"
while true; do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		-i|--ignore-fallures)
			IGNORE_FAILURES=true
			shift
			;;
		-d|--debug)
			DEBUG=true
			SALT_MASTER="${SALT_MASTER:-"127.0.0.1"}"
			MKSQUASHFS_OPTIONS="${MKSQUASHFS_OPTIONS_DEBUG}"
			shift
			;;
		-e|--environment)
			SALT_ENV="$2"
			PILLAR_ENV="$2"
			shift 2
			;;
		-m|--master)
			SALT_MASTER="$2"
			shift 2
			;;
		-t|--tracker)
			ANNOUNCE_URL="$2"
			shift 2
			;;
		-|--)
			shift
			break
			;;
		*)
			exit 3
			;;
	esac
done

CMD="$1"
shift
case "$CMD" in
	build|clean|torrent|genkernel)
		$CMD "$@"
		;;
	*)
		usage
		exit 2
		;;
esac
