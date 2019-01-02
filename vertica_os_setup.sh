#!/bin/bash

TIMEZONE=UTC
IOSCHEDULER=deadline
CLOCKSYNC=ntp
SELINUX=disabled
REBOOT=false

print_help() {
	echo "This is unofficial Vertica OS Setup Script"
	echo ""
	echo "Usage:"
	echo "  ./vertica_os_setup.sh [OPTIONS]..."
	echo ""
	echo "General options"
	echo -e "  -v\tRed Hat/CentOS version (6, 7)"
	echo -e "  -t\tTimezone (default: UTC)"
	echo -e "  -y\tSet clock synchronization method to chrony (v7 only) (default: ntp)"
	echo -e "  -n\tSet I/O scheduling to 'noop', if -s option not used default is 'deadline'"
	echo -e "  -p\tSet SELinux to 'Permissive', if -p option not used default is 'disabled'"
	echo -e "  -r\tReboot after script runs successfully"
	exit 0
}

while getopts "hv:t:p:ynPr" opt; do
	case ${opt} in
		h)
			print_help ;;
		v)
			OSVER=$OPTARG ;;
		t)
			TIMEZONE=$OPTARG ;;
		p)
			ntp_pool=$OPTARG ;;
		y)
			CLOCKSYNC=chrony ;;
		n)
			IOSCHEDULER=noop ;;
		P)
			SELINUX=permissive ;;
		r)
			REBOOT=true ;;
		*)
			echo "ERROR: Unknown Option!"
			echo ""
			print_help
			exit 1
			;;
	esac
done

if [ -z $OSVER ]; then
	echo "Must specify Red Hat/CentOS version (6 or 7) with the -v option"
	exit 1
fi

six=false
sev=false
if [ $OSVER -eq 6 ]; then
	echo "Beginning OS setup for Red Hat/CentOS Version $OSVER"
	six=true
elif [ $OSVER -eq 7 ]; then
	echo "Beginning OS setup for Red Hat/CentOS Version $OSVER"
	sev=true
else
	echo "Unknown version ($OSVER): Valid options are '6' or '7'"
	echo "Exiting now..."
	exit 1
fi


##########################
### Install Packages   ###
##########################

# Package Dependencies: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/RequiredPackages.htm
yum install -y openssh
yum install -y which
yum install -y dialog

# Support Tools: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/supporttools.htm
yum install -y mcelog
yum install -y sysstat
if $six ; then
	yum install -y pstack
else
	yum install -y gdb
fi


##########################
### OS Config Settings ###
##########################

# Firewall Considerations: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/iptablesEnabled.htm
if $six ; then
	service iptables save
	service ip6tables save
	service iptables stop
	service ip6tables stop
	chkconfig iptables off
	chkconfig ip6tables off
else
	systemctl mask firewalld
	systemctl disable firewalld
	systemctl stop firewalld
fi

# Persisting Operating System Settings: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/etcrclocal.htm
if $sev ; then chmod +x /etc/rc.d/rc.local ; fi
if $sev ; then chkconfig tuned off ; fi

# Disk Readahead: http://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/DiskReadahead.htm
/sbin/blockdev --setra 2048 /dev/sda
echo "/sbin/blockdev --setra 2048 /dev/sda" >> /etc/rc.local

# I/O Scheduling: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/IOScheduling.htm
echo $IOSCHEDULER > /sys/block/sda/queue/scheduler
echo "echo $IOSCHEDULER > /sys/block/sda/queue/scheduler" >> /etc/rc.local

# Enabling or Disabling Transparent Hugepages: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/transparenthugepages.htm
if $six ; then
	SET_THP=never
else
	SET_THP=always
fi
echo "if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
    echo $SET_THP > /sys/kernel/mm/transparent_hugepage/enabled
fi" >> /etc/rc.local

# Check for Swappiness: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/CheckforSwappiness.htm
echo 1 > /proc/sys/vm/swappiness
echo 'vm.swappiness=1' >> /etc/sysctl.conf

# Enabling Network Time Protocol (NTP): https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/ntp.htm
if [[ "$sev" = true && "${CLOCKSYNC,,}" == "chrony" ]] ; then
	## Enabling chrony or ntpd for Red Hat 7/CentOS 7 Systems: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/chrony.htm
	yum install -y chrony
	systemctl enable chronyd
else
	yum install -y ntp
	if $six ; then
		service ntpd restart
	else
		systemctl restart ntpd
	fi
	chkconfig ntpd on
fi

# SELinux Configuration: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/SELinux.htm
if [ "${SELINUX,,}" == "permissive" ]; then
	SELINUX=Permissive
	setenforce Permissive
else
	SELINUX=disabled
	setenforce 0
fi
echo "# This file controls the state of SELinux on the system.
# SELINUX= can take one of these three values:
#     enforcing - SELinux security policy is enforced.
#     permissive - SELinux prints warnings instead of enforcing.
#     disabled - No SELinux policy is loaded.
SELINUX=$SELINUX
#SELINUXTYPE= can take one of these two values:
#    targeted - Targeted processes are protected,
#    mls - Multi Level Security protection.
SELINUXTYPE=targeted" > /etc/sysconfig/selinux

# Disable Defrag: https://www.vertica.com/docs/latest/HTML/Content/Authoring/InstallationGuide/BeforeYouInstall/defrag.htm
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo "if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi" >> /etc/rc.local

# TZ Environment Variable: https://www.vertica.com/docs/latest/HTML/index.htm#Authoring/InstallationGuide/BeforeYouInstall/TZenvironmentVar.htm
if [ -n "$ntp_pool" ]; then
	ntpdate -su "$ntp_pool"
fi
if [ -n "$TZ" ]; then
	echo "export TZ=$TZ" >> /etc/profile
fi

# Reboot if -r option used
if $REBOOT ; then
	reboot
fi
