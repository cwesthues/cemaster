#!/bin/sh

# The short cut:

# As root:
# curl -fsSL https://ibm.box.com/shared/static/h0rjy9n4yh4x6zz85sgjty01hl6f1kbl.sh | sh
#
# As non-root:
# curl -fsSL https://ibm.box.com/shared/static/h0rjy9n4yh4x6zz85sgjty01hl6f1kbl.sh | sudo sh

############################################################

RET=`whoami`
if test "${RET}" != "root"
then
   echo "This script has to be executed as root, exiting."
   exit 1
fi

############################################################

cat <<EOF1

############################################################
This script is going to install LSF-CE and SLURM on the local host
as a master node. A gateway is installed to forward LSF/SLURM jobs
as CodeEngine jobs, which is essentially starting a CE docker/k8s
instance and execute the workload there. Furthermore, file exchange
is done through mounting a COS bucket.

In addition, this script can setup a CodeEngine Application 'cemaster'
that can act as a master for LSF/SLURM, access is through guacamole.

To allow CodeEngine instances to be launched, specify upfront:
   export IBMCLOUD_API_KEY="xxxxxxxxxxxxxxxxxxxxxxx"
   export IBMCLOUD_RESOURCE_GROUP="xxx"
   export IBMCLOUD_REGION="xx-xx"
   export IBMCLOUD_PROJECT="xxxxx"

To allow COS mounts, specify upfront:
   export COSBUCKET="xxxxxxxxxxxxx"
   export ACCESS_KEY_ID="xxxxxxxxxxxxxxxxxxxxxxxxxx"
   export SECRET_ACCESS_KEY="xxxxxxxxxxxxxxxxxxxxxx"

To create new docker images, specify upfront:
   export CREATE_IMAGES="y"

To create a cemaster instance, specify upfront:
   export CREATE_CEMASTER_INSTANCE="y"

You can put all these envvar settings into <cwd>/.ce-gateway.conf

cwesthues@de.ibm.com 2024/10/23

############################################################
EOF1

CWD=`pwd`
TOP="/usr/share/lsf"
CLUSTERNAME="cecluster"
CONF="${TOP}/conf/lsf.conf"
SHARED="${TOP}/conf/lsf.shared"
CLUSTER="${TOP}/conf/lsf.cluster.${CLUSTERNAME}"
APPL="${TOP}/conf/lsbatch/${CLUSTERNAME}/configdir/lsb.applications"
PARAMS="${TOP}/conf/lsbatch/${CLUSTERNAME}/configdir/lsb.params"
HOSTS="${TOP}/conf/lsbatch/${CLUSTERNAME}/configdir/lsb.hosts"
ACCT="${TOP}/work/${CLUSTERNAME}/logdir/lsb.codeengine"

PRICE_vCPUsec="0.00003431" # as of 2024/10/05, in US$
PRICE_GBsec="0.00000356"   # as of 2024/10/05, in US$

DATE=`date +%Y%m%d-%Hh%M`
LOG="/var/log/ce-gateway.log"
touch ${LOG}
chmod 777 ${LOG}

if test -f .ce-gateway.conf
then
   echo
   echo "Found .ce-gateway.conf, sourcing..."
   . ./.ce-gateway.conf
fi

if test -f /etc/ce-gateway.conf
then
   echo
   echo "Found /etc/ce-gateway.conf, sourcing..."
   . /etc/ce-gateway.conf
fi

COSMOUNTPATH="/mnt"

#TARGET_USER="lsfadmin"
TARGET_USER="root"
WINDOWMANAGER="fvwm2"
#WINDOWMANAGER="wmaker"

############################################################

RED='\e[1;31m'
GREEN='\e[1;32m'
BLUE='\e[1;34m'
OFF='\e[0;0m'

############################################################

. /etc/os-release
case ${ID_LIKE} in
*rhel*|*fedora*)
   ESC="-e"
;;
*debian*)
;;
esac
echo "Running on ${PRETTY_NAME}"

############################################################

echo
echo "Writing environment variables to logfile" | tee -a ${LOG}
echo "IBMCLOUD_API_KEY=${IBMCLOUD_API_KEY}" >> ${LOG}
echo "IBMCLOUD_RESOURCE_GROUP=${IBMCLOUD_RESOURCE_GROUP}" >> ${LOG}
echo "IBMCLOUD_REGION=${IBMCLOUD_REGION}" >> ${LOG}
echo "IBMCLOUD_PROJECT=${IBMCLOUD_PROJECT}" >> ${LOG}
echo "COSBUCKET=${COSBUCKET}" >> ${LOG}
echo "ACCESS_KEY_ID=${ACCESS_KEY_ID}" >> ${LOG}
echo "SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}" >> ${LOG}
echo "CREATE_IMAGES=${CREATE_IMAGES}" >> ${LOG}
echo "CREATE_CEMASTER_INSTANCE=${CREATE_CEMASTER_INSTANCE}" >> ${LOG}
echo >> ${LOG}

############################################################

if test "${INSIDE_DOCKER}" != ""
then
   echo We are INSIDE a docker build
fi

############################################################

if test ! -f /tmp/various_packages
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing various packages${OFF}"
   echo ${ESC} "${BLUE}===========================${OFF}"

   case ${ID_LIKE} in
   *debian*)
      echo "Installing various packages" >> ${LOG}
      apt-get -yq update >> ${LOG} 2>&1
      export DEBIAN_FRONTEND=noninteractive
      apt -y -qq install \
      bc curl ed git htop imagemagick iproute2 net-tools \
      python3-pip unzip vim xterm wget >> ${LOG} 2>&1
   ;;
   esac
   touch /tmp/various_packages
fi

############################################################

if test ! -f /tmp/handling_users
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Handling users${OFF}"
   echo ${ESC} "${BLUE}==============${OFF}"

   echo "Handling users" >> ${LOG}
   adduser lsfadmin >> ${LOG} 2>&1
   case ${ID_LIKE} in
   *rhel*|*fedora*)
      echo "lsfadmin" | passwd --stdin lsfadmin >> ${LOG} 2>&1
   ;;
   *debian*)
      echo "lsfadmin:lsfadmin" | chpasswd >> ${LOG} 2>&1
   ;;
   esac

   if test "${INSIDE_DOCKER}" != ""
   then
      case ${ID_LIKE} in
      *rhel*|*fedora*)
         echo "root" | passwd --stdin root >> ${LOG} 2>&1
      ;;
      *debian*)
         echo "root:root" | chpasswd >> ${LOG} 2>&1
      ;;
      esac
   fi
   touch /tmp/handling_users
fi

############################################################

if test ! -f /etc/slurm/slurm.conf
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing SLURM${OFF} (~10s)"
   echo ${ESC} "${BLUE}================${OFF}"

   echo "Installing SLURM" >> ${LOG}
   echo "Adding users" | tee -a ${LOG}
   export MUNGEUSER=966
   groupadd -g $MUNGEUSER munge >> ${LOG} 2>&1
   useradd  -m -d /var/lib/munge -u $MUNGEUSER -g munge  -s /sbin/nologin munge >> ${LOG} 2>&1
   export SLURMUSER=967
   groupadd -g $SLURMUSER slurm >> ${LOG} 2>&1
   useradd  -m -d /var/lib/slurm -u $SLURMUSER -g slurm  -s /bin/bash slurm >> ${LOG} 2>&1

   echo "Getting SLURM packages" | tee -a ${LOG}
   rm -rf /tmp/slurm_packages
   mkdir -p /tmp/slurm_packages
   cd /tmp/slurm_packages
   curl -Lo slurm_packages.tgz https://ibm.box.com/shared/static/bzyobp71vu4pehf1d9ey8eloolkmg9f1.tgz >> ${LOG} 2>&1
   tar xvzf slurm_packages.tgz >> ${LOG} 2>&1

   echo "Installing SLURM" | tee -a ${LOG}
   case ${ID_LIKE} in
   *rhel*|*fedora*)
      yum -y --nogpgcheck install munge munge-libs >> ${LOG} 2>&1
      dnf -y --enablerepo=crb install mariadb-devel munge-devel >> ${LOG} 2>&1
      yum -y --nogpgcheck install rng-tools >> ${LOG} 2>&1
      rngd -r /dev/urandom >> ${LOG} 2>&1
      yum -y install *.rpm >> ${LOG} 2>&1
   ;;
   *debian*)
      apt -y install hwloc munge >> ${LOG} 2>&1
      apt -y install ./*.deb >> ${LOG} 2>&1
   ;;
   esac

   /usr/sbin/create-munge-key -r -f >> ${LOG} 2>&1
   sh -c  "dd if=/dev/urandom bs=1 count=32 > /etc/munge/munge.key 2>/dev/null" >> ${LOG} 2>&1

   chown munge: /etc/munge/munge.key
   chmod 400 /etc/munge/munge.key

   echo "Writing /etc/slurm/slurm.conf" | tee -a ${LOG}
   mkdir -p /etc/slurm
   cat > /etc/slurm/slurm.conf <<EOF1
ClusterName=cecluster
SlurmctldHost=localhost
ProctrackType=proctrack/linuxproc
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmctldPort=6817
SlurmdPidFile=/var/run/slurmd.pid
SlurmdPort=6818
SlurmdSpoolDir=/var/lib/slurm/slurmd
SlurmUser=slurm
StateSaveLocation=/var/lib/slurm/slurmctld
TaskPlugin=task/none
InactiveLimit=0
KillWait=30
SlurmctldTimeout=120
SlurmdTimeout=300
Waittime=0
SelectType=select/cons_tres
SelectTypeParameters=CR_Core
AccountingStorageType=accounting_storage/none
JobCompType=jobcomp/none
JobAcctGatherFrequency=30
NodeName=localhost State=UNKNOWN
PartitionName=LocalQ Nodes=ALL Default=YES MaxTime=INFINITE State=UP OverSubscribe=FORCE:999
Prolog=/usr/bin/codeengine-pre.sh
Epilog=/usr/bin/codeengine-post.sh
EOF1
   if test "${INSIDE_DOCKER}" = ""
   then
      echo "Starting slurm daemons"
      systemctl enable munge >> ${LOG} 2>&1
      systemctl start munge >> ${LOG} 2>&1
      systemctl enable slurmctld >> ${LOG} 2>&1
      systemctl start slurmctld >> ${LOG} 2>&1
      systemctl enable slurmd >> ${LOG} 2>&1
      systemctl start slurmd >> ${LOG} 2>&1
   fi
fi

#-------------------------------------------------
## Based upon:
## https://www.ni-sp.com/slurm-build-script-and-container-commercial-support/
#
#. /etc/os-release
#VER="24.05.3"
#
#echo "Compiling slurm"
#yum -y --nogpgcheck install gtk2-devel 1>/dev/null 2>/dev/null
#yum -y --nogpgcheck install python3 gcc openssl openssl-devel pam-devel numactl numactl-devel hwloc lua readline-devel ncurses-devel man2html libibmad libibumad rpm-build  perl-ExtUtils-MakeMaker.noarch perl-devel dbus-devel 1>/dev/null 2>/dev/null
#yum -y --nogpgcheck install rpm-build make 1>/dev/null 2>/dev/null
#dnf -y --enablerepo=crb install rrdtool-devel lua-devel hwloc-devel 1>/dev/null 2>/dev/null
#dnf -y --enablerepo=crb install mariadb-devel munge-devel autoconf automake 1>/dev/null 2>/dev/null
#
#
#mkdir -p /tmp/slurm-tmp
#cd /tmp/slurm-tmp
#rm -rf slurm-${VER}.tar.bz2
#wget https://download.schedmd.com/slurm/slurm-${VER}.tar.bz2
## 1>/dev/null 2>/dev/null
#echo "Running rpmbuild"
#rpmbuild -ta slurm-$VER.tar.bz2 --define '_lto_cflags %{nil}' 1>/dev/null 2>/dev/null
#rm slurm-$VER.tar.bz2
#cd ..
#rmdir /tmp/slurm-tmp
#
#mkdir -p /mnt/hgfs/C/work/SLURM_Packages
#cd /root/rpmbuild/RPMS/x86_64
#cp slurm-24.05.3-1.el9.x86_64.rpm slurm-slurmctld-24.05.3-1.el9.x86_64.rpm slurm-slurmd-24.05.3-1.el9.x86_64.rpm /mnt/hgfs/C/work/SLURM_Packages
#
## Find .rpm's under ~/rpmbuild/RPMS/x86_64
## 
## On a ubuntu node:
#apt update
#apt -y install alien
#cp -r /mnt/hgfs/C/work/SLURM_Packages /root
#cd /root/SLURM_Packages
#alien *.rpm
#cp *.deb /mnt/hgfs/C/work/SLURM_Packages
#cd /mnt/hgfs/C/work/SLURM_Packages
#tar cvzf SLURM_Packages.tgz *.deb *.rpm
#
## https://ibm.box.com/shared/static/bzyobp71vu4pehf1d9ey8eloolkmg9f1.tgz
#-------------------------------------------------
############################################################

if test ! -f /tmp/lsf10.1_linux2.6-glibc2.3-x86_64.tar.Z
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Downloading LSF${OFF} (~90s)"
   echo ${ESC} "${BLUE}===============${OFF}"

   echo "Downloading lsfsce10.2.0.12-x86_64.tar.gz" | tee -a ${LOG}
   cd /tmp
   rm -rf lsf*
   curl -Lo lsfsce10.2.0.12-x86_64.tar.gz https://ibm.box.com/shared/static/owp1764fmw4cp7b1nqwp67jzs1cranhr.gz >> ${LOG} 2>&1
   tar xvzf lsfsce10.2.0.12-x86_64.tar.gz >> ${LOG} 2>&1
   mv lsfsce10.2.0.12-x86_64/lsf/lsf10* /tmp
   mv lsfsce10.2.0.12-x86_64/pac/pac10* /tmp
   rm -rf /tmp/lsfsce10.2.0.12-x86_64 /tmp/lsfsce10.2.0.12-x86_64.tar.gz
fi

if test ! -d /usr/share/lsf
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing LSF${OFF} (~30s)"
   echo ${ESC} "${BLUE}==============${OFF}"

   echo "Installing LSF" >> ${LOG}
   cd /tmp
   tar xvzf lsf10.1_lsfinstall_linux_x86_64.tar.Z >> ${LOG} 2>&1
   cd lsf10.1_lsfinstall
   sed -i s/"^get_java_bin_ext$"/"return 0"/g instlib/lsflib.sh
   HOSTNAME=`hostname -s`
   cat > install.config <<EOF1
LSF_TOP="/usr/share/lsf"
LSF_ADMINS="lsfadmin
LSF_CLUSTER_NAME="cecluster"
LSF_MASTER_LIST="${HOSTNAME}"
EOF1
   cat > answer <<EOF1
1

EOF1
   chmod 755 /lib/x86_64-linux-gnu/libc.so.6 >> ${LOG} 2>&1
   cat answer | ./lsfinstall -f install.config >> ${LOG} 2>&1
   ln -s /usr/share/lsf/conf/profile.lsf /etc/profile.d/lsf.sh
   echo ". /usr/share/lsf/conf/profile.lsf" >> /root/.bashrc
   echo ". /usr/share/lsf/conf/profile.lsf" >> /home/lsfadmin/.bashrc
   . /usr/share/lsf/conf/profile.lsf 
   export MYSQL_JDBC_DRIVER_JAR="/usr/share/java/mysql-connector-java.jar"

   cp /usr/share/lsf/10.1/install/instlib/startup.svr4 /usr/share/lsf/10.1/linux2.6-glibc2.3-x86_64/etc/lsf_daemons
   sed -i s/"@LSF_CONF@"/"\/usr\/share\/lsf\/conf\/lsf.conf"/g /usr/share/lsf/10.1/linux2.6-glibc2.3-x86_64/etc/lsf_daemons
   echo "Running hostsetup" | tee -a ${LOG}
   /usr/share/lsf/10.1/install/hostsetup --boot=y --top=/usr/share/lsf >> ${LOG} 2>&1
   STRING="ENABLE_EVENT_STREAM=y"
   sed -i s/"End Parameters"/"${STRING}\nEnd Parameters"/g ${PARAMS}
   if test "${INSIDE_DOCKER}" = ""
   then
      echo "Starting LSF daemons" | tee -a ${LOG}
      systemctl start lsfd >> ${LOG} 2>&1
   fi   
fi

############################################################

if test ! -d /opt/ibm/lsfsuite/ext/gui
then
   MEM=`egrep "MemTotal:" /proc/meminfo | awk '{print $2}'`
   if test ${MEM} -le 3500000
   then
      echo
      echo "Sorry, not enough mem for Application Center, give node 4GB or more." | tee -a ${LOG}
      echo
   else
      echo ${ESC} ""
      echo ${ESC} "${BLUE}Installing Application Center${OFF} (~90s)"
      echo ${ESC} "${BLUE}=============================${OFF}"

      echo "Installing Application Center" >> ${LOG}
      echo "Installing mysql" | tee -a ${LOG}
      case ${ID_LIKE} in
      *rhel*|*fedora*)
         yum -y install mysql mysql-server >> ${LOG} 2>&1
         systemctl enable mysqld >> ${LOG} 2>&1
         systemctl start mysqld >> ${LOG} 2>&1
      ;;
      *debian*)
         apt -y update >> ${LOG} 2>&1
         apt -y install mysql-server rpm >> ${LOG} 2>&1
      ;;       
      esac
      echo "Starting AC installer" | tee -a ${LOG}
      INSTDIR="/tmp/pacinst.$$"
      mkdir -p ${INSTDIR}
      cd ${INSTDIR}
      tar xvzf /tmp/pac10.2.0.12_standard_linux-x64.tar.Z >> ${LOG} 2>&1
      cd pac*
      export MYSQL_JDBC_DRIVER_JAR="/usr/share/java/mysql-connector-java.jar"
      sed -i -e s/"https"/"http"/g -e s/"read -s passwd"/""/g -e s/"read answer"/"answer=y"/g pacinstall.sh
      chmod 755 pacinstall.sh
      . /usr/share/lsf/conf/profile.lsf
      ./pacinstall.sh -y >> ${LOG} 2>&1
      sed -i s/"-Ddefault.novnc.port=6080"/"#-Ddefault.novnc.port=6080"/g /opt/ibm/lsfsuite/ext/gui/conf/jvm.options
      PMC_CONF="/opt/ibm/lsfsuite/ext/gui/conf/pmc.conf"
      sed -i s/"HELP_URL_PREFIX=http:\/\/www-01.ibm.com\/support\/knowledgecenter"/"HELP_URL_PREFIX=\/help"/g ${PMC_CONF}

      echo "Starting AC services" | tee -a ${LOG}

      cat > /opt/ibm/lsfsuite/ext/gui/3.0/bin/ac_daemons <<EOF
#!/bin/bash
source /opt/ibm/lsfsuite/ext/profile.platform
OP=\$1
if [ "x\${OP}" = "x" ]; then
    exit 1
fi
perfadmin \${OP} all
pmcadmin \${OP}
exit 0
EOF
      chmod 755 /opt/ibm/lsfsuite/ext/gui/3.0/bin/ac_daemons

      cat > /etc/systemd/system/acd.service <<EOF
[Unit]
Description=IBM Spectrum LSF Application Center
After=network.target nfs.service autofs.service gpfs.service

[Service]
Type=forking
ExecStart=/opt/ibm/lsfsuite/ext/gui/3.0/bin/ac_daemons start
ExecStop=/opt/ibm/lsfsuite/ext/gui/3.0/bin/ac_daemons stop

[Install]
WantedBy=multi-user.target
EOF

      systemctl enable acd >> ${LOG} 2>&1
      systemctl start acd >> ${LOG} 2>&1

      echo "Creating desktop icon" | tee -a ${LOG}
      DESKTOP_LINK="/root/Desktop/AC.desktop"
      URL="http://localhost:8080"
      cat << EOF > ${DESKTOP_LINK}
[Desktop Entry]
Type=Application
Terminal=false
Exec=firefox ${URL}
Name=AC
Icon=firefox
EOF
      gio set ${DESKTOP_LINK} "metadata::trusted" true
      chmod 755 "${DESKTOP_LINK}"

      echo "Modifying AC template for calculate_pi" | tee -a ${LOG}

      cat > /opt/ibm/lsfsuite/ext/gui/conf/application/published/generic/generic.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<agent type="generic" application="calculate_pi" resources="resources">
  <info>Submit a job: calculate_pi</info>
  <action id="submit" label="submit" result="text/xml">generic.cmd</action>
  <repository>
    <application id="application" state="expandEnable" info="Job Options">
      <option defaultValue="calculate_pi.sh" id="COMMANDTORUN" label="Command" required="true" hidden="false" type="text" editable="true"></option>
      <option defaultValue="" id="JOB_NAME" label="Job Name" required="false" hidden="false" type="text" editable="true"></option>

      <option defaultValue="-resources=0.5x1" id="CODEENGINE_OPTIONS" label="CE size" required="false" hidden="false" type="list" editable="true">
        <option id="-resources=0.125x0.25" required="false" hidden="false"                >0.125 vCPU 0.25 GB</option>
        <option id="-resources=0.125x0.5"  required="false" hidden="false"                >0.125 vCPU 0.5 GB</option>
        <option id="-resources=0.125x1"    required="false" hidden="false"                >0.125 vCPU 1 GB</option>
        <option id="-resources=0.25x0.5"   required="false" hidden="false"                >0.25 vCPU 0.5 GB</option>
        <option id="-resources=0.25x1"     required="false" hidden="false"                >0.25 vCPU 1 GB</option>
        <option id="-resources=0.25x2"     required="false" hidden="false"                >0.25 vCPU 2 GB</option>
        <option id="-resources=0.5x1"      required="false" hidden="false" selected="true">0.5 vCPU 1 GB</option>
        <option id="-resources=0.5x2"      required="false" hidden="false"                >0.5 vCPU 2 GB</option>
        <option id="-resources=0.5x4"      required="false" hidden="false"                >0.5 vCPU 4 GB</option>
        <option id="-resources=1x2"        required="false" hidden="false"                >1 vCPU 2 GB</option>
        <option id="-resources=1x4"        required="false" hidden="false"                >1 vCPU 4 GB</option>
        <option id="-resources=1x8"        required="false" hidden="false"                >1 vCPU 8 GB</option>
        <option id="-resources=2x4"        required="false" hidden="false"                >2 vCPU 4 GB</option>
        <option id="-resources=2x8"        required="false" hidden="false"                >2 vCPU 8 GB</option>
        <option id="-resources=2x16"       required="false" hidden="false"                >2 vCPU 16 GB</option>
        <option id="-resources=4x8"        required="false" hidden="false"                >4 vCPU 8 GB</option>
        <option id="-resources=4x16"       required="false" hidden="false"                >4 vCPU 16 GB</option>
        <option id="-resources=4x32"       required="false" hidden="false"                >4 vCPU 32 GB</option>
        <option id="-resources=6x12"       required="false" hidden="false"                >6 vCPU 12 GB</option>
        <option id="-resources=6x24"       required="false" hidden="false"                >6 vCPU 24 GB</option>
        <option id="-resources=6x48"       required="false" hidden="false"                >6 vCPU 48 GB</option>
        <option id="-resources=8x16"       required="false" hidden="false"                >8 vCPU 16 GB</option>
        <option id="-resources=8x32"       required="false" hidden="false"                >8 vCPU 32 GB</option>
        <option id="-resources=10x20"      required="false" hidden="false"                >10 vCPU 20 GB</option>
        <option id="-resources=10x40"      required="false" hidden="false"                >10 vCPU 40 GB</option>
        <option id="-resources=12x24"      required="false" hidden="false"                >12 vCPU 24 GB</option>
        <option id="-resources=12x48"      required="false" hidden="false"                >12 vCPU 48 GB</option>
      </option>
      <option defaultValue="rocky" id="CODEENGINE_IMAGE" label="CE image" required="false" hidden="false" type="list" editable="true">
        <option id="rocky"      required="false" hidden="false" selected="true">rocky</option>
        <option id="ubuntu"     required="false" hidden="false">ubuntu</option>
      </option>
      <option defaultValue="codeengine" id="APPLICATION" label="Application" required="false" hidden="false" type="list" editable="true">
        <action id="app_profile">\$GUI_CONFDIR/application/options/bapp.sh </action>
      </option>
      <option defaultValue="normal" id="QUEUE" label="Queue" required="false" hidden="false" type="list" editable="true">
        <action id="queues">\$GUI_CONFDIR/application/options/queue.sh normal</action>
      </option>
      <option defaultValue="1000" id="ITERATIONS" label="Iterations" required="false" hidden="false" type="text" editable="true">1000</option>
      <option id="OUTPUT_FILE" label="Output file" required="false" hidden="false" type="text" editable="true">out.txt</option>
    </application>
  </repository>
</agent>
EOF

      cat > /opt/ibm/lsfsuite/ext/gui/conf/application/published/generic/generic.cmd <<EOF
#!/bin/bash

#echo CODEENGINE_OPTIONS is \${CODEENGINE_OPTIONS} >> /tmp/sepp
#echo CODEENGINE_IMAGE is \${CODEENGINE_IMAGE} >> /tmp/sepp
#echo QUEUE is \${QUEUE} >> /tmp/sepp
#echo APPLICATION is \${APPLICATION} >> /tmp/sepp
#echo COMMANDTORUN \${COMMANDTORUN} >> /tmp/sepp
#echo ITERATIONS \${ITERATIONS} >> /tmp/sepp
#echo OUTPUT_FILE \${OUTPUT_FILE} >> /tmp/sepp
#bsub -app \${APPLICATION} -q \${QUEUE} \${COMMANDTORUN} \${ITERATIONS} 2>&1

JOB_RESULT=\`/bin/sh -c "bsub -app \${APPLICATION} -q \${QUEUE} -o \${OUTPUT_FILE} \${COMMANDTORUN} \${ITERATIONS} 2>&1"\`

export JOB_RESULT OUTPUT_FILE_LOCATION
\${GUI_CONFDIR}/application/job-result.sh
EOF
      chown -R lsfadmin:lsfadmin /opt/ibm/lsfsuite/ext/gui/conf/application/published/generic
      chmod 755 /opt/ibm/lsfsuite/ext/gui/conf/application/published/generic/generic.cmd
      rm -rf /opt/ibm/lsfsuite/ext/gui/conf/application/published/GEDIT
   fi
fi

############################################################

RET=`which ibmcloud 2>/dev/null`
if test "${RET}" = ""
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing IBM CLI${OFF}"
   echo ${ESC} "${BLUE}==================${OFF}"
   echo "Installing IBM CLI" >> ${LOG}
   curl -fsSL https://clis.cloud.ibm.com/install/linux | sh >> ${LOG} 2>&1
fi

############################################################

RET=`which kubectl 2>/dev/null`
if test "${RET}" = ""
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing kubectl${OFF}"
   echo ${ESC} "${BLUE}==================${OFF}"
   echo "Installing kubectl" >> ${LOG}   
   cd /usr/bin
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" >> ${LOG} 2>&1
   chmod 755 kubectl
fi

############################################################

case ${ID_LIKE} in
*rhel*|*fedora*)
   RET=`rpm -qa | egrep docker-ce`
;;
*debian*)
   RET=`apt list 2>/dev/null | egrep docker-ce | egrep installed`
;;
esac

if test "${RET}" = ""
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing docker-ce${OFF}"
   echo ${ESC} "${BLUE}====================${OFF}"

   echo "Installing docker-ce" >> ${LOG}
   case ${ID_LIKE} in
   *rhel*|*fedora*)
      dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo >> ${LOG} 2>&1
      yum -y remove podman-docker runc >> ${LOG} 2>&1
      yum -y install docker-ce >> ${LOG} 2>&1
   ;;
   *debian*)
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - >> ${LOG} 2>&1
      add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable" >> ${LOG} 2>&1
      apt install -y docker-ce docker-ce-cli containerd.io >> ${LOG} 2>&1
   ;;
   esac

   echo ${ESC} ""
   echo ${ESC} "${BLUE}Enabling and starting docker service${OFF}"
   echo ${ESC} "${BLUE}====================================${OFF}"

   echo "Enabling and starting docker service" >> ${LOG}
   systemctl enable docker >> ${LOG} 2>&1
   systemctl start docker >> ${LOG} 2>&1

   gpasswd -a lsfadmin docker >> ${LOG} 2>&1
   touch /etc/containers/nodocker >> ${LOG} 2>&1
fi

############################################################

RET=`which s3fs 2>/dev/null`
if test "${RET}" = ""
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing s3fs${OFF}"
   echo ${ESC} "${BLUE}===============${OFF}"

   echo "Installing s3fs" >> ${LOG}
   case ${ID_LIKE} in
   *rhel*|*fedora*)
      yum -y --nogpgcheck install epel-release s3fs-fuse >> ${LOG} 2>&1
   ;;
   *debian*)
      apt -y install s3fs >> ${LOG} 2>&1
   ;;
   esac
fi

############################################################

if test "${INSIDE_DOCKER}" != ""
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Installing windowmanager and VNC${OFF}"
   echo ${ESC} "${BLUE}================================${OFF}"

   case ${ID_LIKE} in
   *debian*)
      export DEBIAN_FRONTEND=noninteractive
      apt -y -qq install tigervnc-standalone-server 1>/dev/null 2>/dev/null
      apt -y -qq install fvwm 1>/dev/null 2>/dev/null
      #apt -y -qq install wmaker 1>/dev/null 2>/dev/null

   ;;
   esac
   mkdir -p /config/guacamole

   cat > /config/guacamole/guacamole.properties <<EOF1
postgresql-hostname: localhost
postgresql-port: 5432
postgresql-database: guacamole_db
postgresql-username: guacamole
postgresql-password: null

enable-clipboard-integration: true

user-mapping:       /configure/guacamole/user-mapping.xml
EOF1

   cat > /config/guacamole/user-mapping.xml <<EOF1
<user-mapping>
        <authorize username="lsfadmin" password="lsfadmin" >
                <connection name="127.0.0.1 VNC lsfadmin fvwm2">
                        <protocol>vnc</protocol>
                        <param name="hostname">localhost</param>
                        <param name="port">5901</param>
                        <param name="username">lsfadmin</param>
                        <param name="password">lsfadmin</param>
                </connection>
        </authorize>
</user-mapping>
EOF1

TARGET_USER="${TARGET_USER}"
WINDOWMANAGER="${WINDOWMANAGER}"

   sed -i s/"\$\[infostore.terminal\]"/"xterm -bg white -fg black -sb -rightbar -fn \"-*-fixed-*-*-*-*-20-*-*-*-*-*-*-*\""/g /usr/share/fvwm2/default-config/config

   SIZE="1024x768"
   WIDTH=`echo ${SIZE} | awk 'BEGIN{FS="x"}{print $1}'`
   POINTSIZE=`expr ${WIDTH} / 10`
   convert -size ${SIZE} xc:white -pointsize ${POINTSIZE} -gravity center label:"cemaster" /usr/share/fvwm2/default-config/images/background/bg1.png
   mv /usr/share/fvwm2/default-config/images/background/bg1-1.png /usr/share/fvwm2/default-config/images/background/bg1.png

case "${TARGET_USER}" in
root)
   echo "${WINDOWMANAGER}" > /root/.xsession

   mkdir -p /root/.vnc
   echo "lsfadmin" | tigervncpasswd -f > /root/.vnc/passwd
   chmod 600 /root/.vnc/passwd
   cat > /root/.vnc/config <<EOF2
geometry=1024x768
dpi=150
EOF2
;;
lsfadmin)
   echo "${WINDOWMANAGER}" > /home/lsfadmin/.xsession
   chown lsfadmin:lsfadmin /home/lsfadmin/.session

   mkdir -p /home/lsfadmin/.vnc
   echo "lsfadmin" | tigervncpasswd -f > /home/lsfadmin/.vnc/passwd
   chmod 600 /home/lsfadmin/.vnc/passwd
   cat > /home/lsfadmin/.vnc/config <<EOF2
geometry=1024x768
EOF2
   chown -R lsfadmin:lsfadmin /home/lsfadmin/.vnc
;;
esac

   cat > /etc/services.d/guacd/run <<EOF1
#!/usr/bin/with-contenv sh

# CWE
TARGET_USER="${TARGET_USER}"
case "\${TARGET_USER}" in
root)
   cd /root
   tigervncserver &
;;
lsfadmin)
   cd /home/lsfadmin
   sudo -u lsfadmin tigervncserver &
;;
esac
if test -f /usr/share/lsf/conf/lsf.conf
then
   HOSTNAME=\`hostname -s\`
   sed -i s/"buildkitsandbox"/"\${HOSTNAME}"/g /usr/share/lsf/conf/lsf.conf
   sed -i s/"buildkitsandbox"/"\${HOSTNAME}"/g /usr/share/lsf/conf/lsf.cluster.cecluster
   . /usr/share/lsf/conf/profile.lsf
   lsf_daemons start
fi
if test -f /etc/slurm/slurm.conf
then
   /etc/init.d/munge start
   /usr/sbin/slurmd -D &
   /usr/sbin/slurmctld -D &
#   /etc/init.d/slurmctld start
#   /etc/init.d/slurmd start
fi
# CWE

s6-setuidgid root guacd -f -L debug -b 127.0.0.1 &

while true
do
   sleep 30
   echo XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
   echo Running guacd procs:
   ps -edafl | egrep guacd | egrep -v grep
   echo XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
done
EOF1
   chmod 755 /etc/services.d/guacd/run
fi

############################################################
   
if test "${INSIDE_DOCKER}" = "" -a "${CREATE_IMAGES}" = "y" -a \
        "${DOCKERUSER}" != "" -a "${DOCKERTOKEN}" != ""
then
   docker login -u ${DOCKERUSER} -p ${DOCKERTOKEN} docker.io >> ${LOG} 2>&1

   FOUND=`docker search ${DOCKERUSER} | egrep ${DOCKERUSER} | awk '{printf("%s\n",$1)}'`
   if test "${FOUND}" != ""
   then
      echo
      echo "Found the following images:"
      echo ${FOUND} | awk '{for(i=1;i<=NF;i++){printf("%s\n",$i)}}'
      echo
   fi

   if test "${CREATE_IMAGES}" = "y"
   then
      rm -rf /tmp/Dockerbuild
      mkdir -p /tmp/Dockerbuild
      cd /tmp/Dockerbuild
      cp /tmp/lsf10.1_linux2.6-glibc2.3-x86_64.tar.Z .
      cp /tmp/lsf10.1_lsfinstall_linux_x86_64.tar.Z .
      BASENAME=`basename $0`
      cp ${CWD}/$0 ./${BASENAME}
      cat > ce-gateway.conf <<EOF1
export DOCKERUSER="${DOCKERUSER}"
export DOCKERTOKEN="${DOCKERTOKEN}"

export IBMCLOUD_API_KEY="${IBMCLOUD_API_KEY}"
export IBMCLOUD_RESOURCE_GROUP="${IBMCLOUD_RESOURCE_GROUP}"
export IBMCLOUD_REGION="${IBMCLOUD_REGION}"
export IBMCLOUD_PROJECT="${IBMCLOUD_PROJECT}"

export COSBUCKET="${COSBUCKET}"
export ACCESS_KEY_ID="${ACCESS_KEY_ID}"
export SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}"
EOF1
      echo "Write Dockerfile for cemaster"
      cat > Dockerfile <<EOF1
FROM docker.io/jwetzell/guacamole:latest
ENV INSIDE_DOCKER="true"
COPY lsf10.1_linux2.6-glibc2.3-x86_64.tar.Z /tmp
COPY lsf10.1_lsfinstall_linux_x86_64.tar.Z /tmp
COPY ${BASENAME} /tmp
COPY ce-gateway.conf /etc/ce-gateway.conf
RUN /tmp/${BASENAME}
#RUN echo "root:root" | chpasswd
EXPOSE 8080
EOF1
      echo
      echo "Docker build for cemaster"
      echo -e "${BLUE}   docker build -t docker.io/${DOCKERUSER}/cemaster:${DATE} .${OFF}"
      docker build -t docker.io/${DOCKERUSER}/cemaster .




      echo "Docker push"
      echo -e "${BLUE}   docker push docker.io/${DOCKERUSER}/cemaster:${DATE}${OFF}"
      docker push docker.io/${DOCKERUSER}/cemaster

      cat > /tmp/calculate_pi.sh <<EOF1
#!/bin/bash

# Function to calculate Pi using the Leibniz series
calculate_pi() {
   local iterations=\$1
   local pi=0
   local sign=1

   echo
   echo "Iterations: \$1"
   echo
   for (( i=0; i<\$iterations; i++ ))
   do
      # Calculate the term in the series: 4 * (1 / (2*i + 1)) * sign
      term=\$(echo "scale=15; 4 * \$sign / (2 * \$i + 1)" | bc)
      pi=\$(echo "scale=15; \$pi + \$term" | bc)
      # Flip the sign for the next term
      sign=\$(( -1 * \$sign ))
   done
   echo "Calculated value of Pi: \$pi"
}

# Check if the user has provided the number of iterations
if [ -z "\$1" ]
then
   echo "Usage: \$0 <number_of_iterations>"
   exit 1
fi

# Call the function with the user-provided number of iterations
calculate_pi \$1
EOF1
      chmod 755 /tmp/calculate_pi.sh

      rm -rf /tmp/Dockerbuild
      mkdir -p /tmp/Dockerbuild
      cd /tmp/Dockerbuild
      cp /tmp/calculate_pi.sh .
      echo
      echo "############################################################"
      echo "Write Dockerfile for ubuntu"

      cat > Dockerfile <<EOF1
FROM docker.io/library/ubuntu:latest
RUN apt-get -yq update ; export DEBIAN_FRONTEND=noninteractive ; apt -y -qq install bc curl git iproute2 net-tools python3-pip unzip wget
COPY calculate_pi.sh /usr/bin/calculate_pi.sh
EOF1
      echo
      echo "Docker build for ubuntu"
      echo ${ESC} "${BLUE}   docker build -t docker.io/${DOCKERUSER}/ubuntu:${DATE} .${OFF}"
      docker build -t docker.io/${DOCKERUSER}/ubuntu .
      echo "Docker push"
      echo ${ESC} "${BLUE}   docker push docker.io/${DOCKERUSER}/ubuntu:${DATE}${OFF}"
      docker push docker.io/${DOCKERUSER}/ubuntu
      rm -rf /tmp/Dockerbuild

      rm -rf /tmp/Dockerbuild
      mkdir -p /tmp/Dockerbuild
      cd /tmp/Dockerbuild
      cp /tmp/calculate_pi.sh .
      echo "Write Dockerfile for rocky"
      cat > Dockerfile <<EOF1
FROM rockylinux/rockylinux:latest
RUN yum -y --nogpgcheck install bc curl epel-release git iproute net-tools python3-pip unzip wget which
COPY calculate_pi.sh /usr/bin/calculate_pi.sh
EOF1
      echo
      echo "Docker build for rocky"
      echo ${ESC} "${BLUE}   docker build -t docker.io/${DOCKERUSER}/rocky:${DATE} .${OFF}"
      docker build -t docker.io/${DOCKERUSER}/rocky .
      echo "Docker push"
      echo ${ESC} "${BLUE}   docker push docker.io/${DOCKERUSER}/rocky:${DATE}${OFF}"
      docker push docker.io/${DOCKERUSER}/rocky
      rm -rf /tmp/Dockerbuild
   fi
fi

############################################################

cd
if test "${INSIDE_DOCKER}" = ""
then
   if test "${CREATE_CEMASTER_INSTANCE}" = "y"
   then
      RET=`ibmcloud plugin list | egrep code-engine`
      if test "${RET}" = ""
      then
         ibmcloud plugin install ce -f 1>/dev/null 2>/dev/null
      fi
      ibmcloud login -r ${IBMCLOUD_REGION} -q 2>/dev/null | egrep '(Account:|User:)' 1>/dev/null 2>/dev/null
      ibmcloud target -r ${IBMCLOUD_REGION} -g ${IBMCLOUD_RESOURCE_GROUP} 1>/dev/null 2>/dev/null
      PROJECT=`ibmcloud ce project list | egrep ${IBMCLOUD_REGION} | egrep active | awk '{print $1}' | sort | tail -1`
      ibmcloud ce project select -n ${PROJECT} 1>/dev/null 2>/dev/null

      RET=`ibmcloud ce app list | egrep cemaster`
      if test "${RET}" != ""
      then
         echo "Found existing instance of cemaster, deleting."
         ibmcloud ce app delete  --name cemaster -f
      fi	      

      ibmcloud ce app create --name cemaster \
        --image docker.io/${DOCKERUSER}/cemaster:latest \
        --port 8080 \
        --cpu 0.25 \
        --memory 1G \
        --min-scale 0 \
        --max-scale 1

      echo URL:
      ibmcloud ce app get --name cemaster --output url

      cat > log_cemaster.sh <<EOF1
INST=\`ibmcloud ce app get --name cemaster | egrep Running  | tail -1 | awk '{print \$1}'\`
ibmcloud ce app logs --instance \$INST
EOF1
      chmod 755 log_cemaster.sh
   fi
fi

############################################################

echo ${ESC} ""
echo ${ESC} "${BLUE}Remove any orphaned CE jobs/jobruns${OFF}"
echo ${ESC} "${BLUE}===================================${OFF}"

cd
RET=`ibmcloud plugin list | egrep code-engine`
if test "${RET}" = ""
then
   ibmcloud plugin install ce -f 1>/dev/null 2>/dev/null
fi
ibmcloud login -r ${IBMCLOUD_REGION} -q 2>/dev/null | egrep '(Account:|User:)' 1>/dev/null 2>/dev/null
ibmcloud target -r ${IBMCLOUD_REGION} -g ${IBMCLOUD_RESOURCE_GROUP} 1>/dev/null 2>/dev/null
PROJECT=`ibmcloud ce project list | egrep ${IBMCLOUD_REGION} | egrep active | awk '{print $1}' | sort | tail -1`
ibmcloud ce project select -n ${PROJECT} 1>/dev/null 2>/dev/null

JOBRUNS=`ibmcloud ce jobrun list 2>/dev/null | egrep -v '(Name|Listing|OK)' | awk '{print $1}'`
if test "${JOBRUNS}" != ""
then
   for JOBRUN in ${JOBRUNS}
   do
      echo "Delete jobrun ${JOBRUN}"
      ibmcloud ce jobrun delete --name ${JOBRUN} -f 1>/dev/null 2>/dev/null
   done
fi

JOBS=`ibmcloud ce job list 2>/dev/null | egrep -v '(Name|Listing|OK)' | awk '{print $1}'`
if test "${JOBS}" != ""
then
   for JOB in ${JOBS}
   do
      echo "Delete job ${JOB}"
      ibmcloud ce job delete --name ${JOB} -f 1>/dev/null 2>/dev/null
   done
fi

############################################################

RET=`egrep codeengine ${APPL}`
if test "${RET}" = ""
then
   echo ${ESC} ""
   echo ${ESC} "${BLUE}Modifying LSF configuration${OFF}"
   echo ${ESC} "${BLUE}===========================${OFF}"

   echo "LSF_PROCESS_TRACKING=Y" >> ${CONF}
   echo "LSF_LINUX_CGROUP_ACCT=Y" >> ${CONF}
   echo "LSB_RESOURCE_ENFORCE=\"cpu memory\"" >> ${CONF}
   echo "LSF_ROOT_USER=Y" >> ${CONF}

   STRING="   docker     Boolean ()       ()          (Docker container)"
   sed -i s/"End Resource"/"${STRING}\nEnd Resource"/g ${SHARED}
   STRING="   codeengine Boolean ()       ()          (codeengine host)"
   sed -i s/"End Resource"/"${STRING}\nEnd Resource"/g ${SHARED}

   sed -i s/"(mg)"/"(mg docker codeengine)"/g ${CLUSTER}

   cat >> ${APPL} <<EOF1

Begin Application
NAME                 = codeengine
RES_REQ              = select[codeengine]
CONTAINER            = docker[image(\${CODEENGINE_IMAGE}) options(\${CODEENGINE_OPTIONS})]
DESCRIPTION          = Codeengine User Service
EXEC_DRIVER          = context[user(default)] \
   starter[/usr/bin/codeengine-starter.sh] \
   controller[/usr/bin/codeengine-control.sh]
PRE_EXEC             = /usr/bin/codeengine-pre.sh
POST_EXEC            = /usr/bin/codeengine-post.sh
JOB_INCLUDE_POSTPROC = Y
End Application
EOF1
   sed -i s/"default    !"/"default    999"/g ${HOSTS}

   echo "JOBID USER QUEUE PROJECT CORES MEM RUNTIME ELEMENTS CPUSEC MEMSEC PRICE" > ${ACCT}
   chmod 777 ${ACCT}
   chown lsfadmin:lsfadmin ${ACCT}
   systemctl restart lsfd
fi

############################################################

echo ${ESC} ""
echo ${ESC} "${BLUE}Creating codeengine scripts${OFF}"
echo ${ESC} "${BLUE}===========================${OFF}"

cat > /usr/bin/codeengine-starter.sh <<EOF1
#!/bin/sh

RED='\e[1;31m'
GREEN='\e[1;32m'
BLUE='\e[1;34m'
OFF='\e[0;0m'

. /etc/os-release
case \${ID_LIKE} in
*rhel*|*fedora*)
   ESC="-e"
;;
*debian*)
;;
esac

DEFAULT_IMAGE="rocky"
DEFAULT_OPTIONS="-resources=0.25x1"

if test "\${LSB_JOBID}" != ""
then
   NEW_JOBID=\${LSB_JOBID}
   NEW_JOBNAME=\${LSB_JOBNAME}
fi

if test "\${SLURM_JOBID}" != ""
then
   NEW_JOBID=\${SLURM_JOBID}
   NEW_JOBNAME=\${SLURM_JOB_NAME}

fi

DEBUG=""

export IBMCLOUD_API_KEY="${IBMCLOUD_API_KEY}"
export IBMCLOUD_RESOURCE_GROUP="${IBMCLOUD_RESOURCE_GROUP}"
export IBMCLOUD_REGION="${IBMCLOUD_REGION}"
export IBMCLOUD_PROJECT="${IBMCLOUD_PROJECT}"

export COSBUCKET="${COSBUCKET}"
export ACCESS_KEY_ID="${ACCESS_KEY_ID}"
export SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}"

export DOCKERTOKEN="${DOCKERTOKEN}"
export DOCKERUSER="${DOCKERUSER}"

export PRICE_vCPUsec="${PRICE_vCPUsec}"
export PRICE_GBsec="${PRICE_GBsec}"

export LOG="${LOG}"

RET=\`ibmcloud plugin list | egrep code-engine\`
if test "\${RET}" = ""
then
   echo "Install CE plugin" >> \${LOG}
   ibmcloud plugin install ce -f >> \${LOG} 2>&1
fi

RET=\`ibmcloud target 2>/dev/null | egrep Region | awk '{print \$2}'\`
if test "\${RET}" = ""
then
   echo "Login to ibmcloud" >> \${LOG}
   ibmcloud login -r \${IBMCLOUD_REGION} -q 2>/dev/null | egrep '(Account:|User:)' >> \${LOG} 2>&1
fi

RET=\`ibmcloud target | egrep Resource | egrep -v 'No resource group' | awk '{print \$3}'\`
if test "\${RET}" = ""
then
   echo "Target region" >> \${LOG}
   ibmcloud target -r \${IBMCLOUD_REGION} -g \${IBMCLOUD_RESOURCE_GROUP} >> \${LOG} 2>&1
fi

echo "Flag project with --kubecfg" >> \${LOG}
ibmcloud ce project select -n \${IBMCLOUD_PROJECT} --kubecfg >> \${LOG} 2>&1

RET=\`ibmcloud ce project list | awk '{print \$5}' | egrep true\`
if test "\${RET}" = ""
then
   echo "Select project" >> \${LOG}
   ibmcloud ce project select -n \${IBMCLOUD_PROJECT} >> \${LOG} 2>&1
fi

echo "Extract job definition" >> \${LOG}

if test "\${LSB_JOBID}" != ""
then
   PROLOGUE="\
export LSB_JOBID=\${LSB_JOBID} \
export LSB_PROJECT_NAME=\${LSB_PROJECT_NAME} \
export LSB_QUEUE=\${LSB_QUEUE} \
export LSB_SUB_HOST=\${LSB_SUB_HOST} \
export LSB_SUB_USER=\${LSB_SUB_USER} \
; sleep 2 ; "

   RET=\`egrep _USER_SCRIPT_ \$1\`
   if test "\${RET}" = ""
   then
      CMD=\`cat \$1 | sed -n '/LSBATCH: User input/,$'p | egrep -v "LSBATCH: User input" | head -1\`
   else
      sed -i s/"\\\$LSB_JOBFILENAME.shell"/"exit 0"/g \$1
      \$1
      CMD=\`cat \$LSB_CHKFILENAME.shell | egrep -v "^#BSUB"\`
   fi
   echo "Command is:" >> \${LOG}
   echo "\${CMD}" >> \${LOG}
fi

if test "\${SLURM_JOBID}" != ""
then
   PROLOGUE="\
export SLURM_JOBID=\${SLURM_JOBID} \
export SLURM_JOB_ACCOUNT=\${SLURM_JOB_ACCOUNT} \
export SLURM_JOB_PARTITION=\${SLURM_JOB_PARTITION} \
; sleep 2 ; "

   if test -f "\$1"
   then
      CMD=\`cat \$1 | egrep -v "^#SBATCH" | egrep -v "codeengine-starter.sh"\`
   else
      CMD=\$*
   fi
   echo "Command is:" >> \${LOG}
   echo "\${CMD}" >> \${LOG}
fi

if [ "\${CODEENGINE_IMAGE}" = "" ]; then
   echo \${ESC} "CODEENGINE_IMAGE not set, falling back to \${RED}\${DEFAULT_IMAGE}\${OFF}"
   echo \${ESC} "\${BLUE}   -> export CODEENGINE_IMAGE=[ubuntu|rocky]\${OFF}"
   CODEENGINE_IMAGE="\${DEFAULT_IMAGE}"
fi

if [ "\${CODEENGINE_OPTIONS}" = "" ]; then
   echo \${ESC} "CODEENGINE_OPTIONS not set, falling back to \${RED}\${DEFAULT_OPTIONS}"
   echo \${ESC} "\${BLUE}   -> export CODEENGINE_OPTIONS=\"-resources=...\"\${OFF}"
   echo \${ESC} "\${BLUE}      0.125x0.25 0.125x0.5 0.125x1 0.25x0.5 0.25x1 0.25x2\${OFF}"
   echo \${ESC} "\${BLUE}      0.5x1 0.5x2 0.5x4 1x2 1x4 1x8 2x4 2x8 2x16 4x8 4x16\${OFF}"
   echo \${ESC} "\${BLUE}      4x32 6x12 6x24 6x48 8x16 8x32 10x20 10x40 12x24 12x48\${OFF}"
   CODEENGINE_OPTIONS="${CODEENGINE_OPTIONS} ${DEFAULT_OPTIONS}"
fi

RET=\`echo \${NEW_JOBNAME} | fgrep '[' | fgrep ']'\`
if test "\${RET}" != ""
then
   SLURMARRAY=\`echo \${NEW_JOBNAME} | awk 'BEGIN{FS="["}{print \$2}' | awk 'BEGIN{FS="]"}{printf("-array=%s\n",\$1)}'\`
   PURE_JOBNAME=\`echo \${NEW_JOBNAME} | awk 'BEGIN{FS="["}{print \$1}'\`
   CODEENGINE_OPTIONS="\${CODEENGINE_OPTIONS} -array \${SLURMARRAY}"
fi

for ARG in \${CODEENGINE_OPTIONS}
do
   VAR=\`echo \$ARG | awk 'BEGIN{FS="="}{print \$1}'\`
   VAL=\`echo \$ARG | awk 'BEGIN{FS="="}{print \$2}'\`
   case \$VAR in
   -resources)
      CORES=\`echo \${VAL} | awk 'BEGIN{FS="x"}{print \$1}'\`
      MEM=\`echo \${VAL} | awk 'BEGIN{FS="x"}{print \$2}'\`
      RESOURCES="--cpu \${CORES} --memory \${MEM}G"
   ;;
   -array)
      ARRAY="--array-indices \${VAL}"
   ;;
   esac
done

echo "Create job" >> \${LOG}
echo CODEENGINE_IMAGE=\$CONTAINER_IMAGE >> \${LOG}
echo CODEENGINE_OPTIONS=\$CODEENGINE_OPTIONS >> \${LOG}
echo RESOURCES=\$RESOURCES >> \${LOG}

ibmcloud ce job create --name \${NEW_JOBID} --image docker.io/\${DOCKERUSER}/\${CODEENGINE_IMAGE} \${RESOURCES} \${ARRAY} --command /bin/sh --argument "-c" --argument "\${PROLOGUE} \${CMD}" >> \${LOG} 2>&1

echo "Add COS mount patch" >> \${LOG}
add-volume-mount-to-job.sh \${NEW_JOBID} ${COSBUCKET} ${COSMOUNTPATH} >> \${LOG} 2>&1

ACCOUNTING_START=\`date +%s\`

echo "Run job" >> \${LOG}
ibmcloud ce jobrun submit --job \${NEW_JOBID} >> \${LOG} 2>&1

echo "List jobruns until job running" >> \${LOG}
PENDING="1"
RUNNING="1"
while test "\${PENDING}" != "0" -a "\${RUNNING}" != 0
do
   if test "\${DEBUG}" ; then
      ibmcloud ce jobrun list | egrep '(^Name|^'\${NEW_JOBID}')' >> \${LOG} 2>&1
   fi
   sleep 1
   PENDING=\`ibmcloud ce jobrun list | egrep \${NEW_JOBID} | awk '{print \$3}'\`
   RUNNING=\`ibmcloud ce jobrun list | egrep \${NEW_JOBID} | awk '{print \$4}'\`
done

JOBRUN_NAME=\`ibmcloud ce jobrun list | egrep \${NEW_JOBID} | egrep task | awk '{print \$1}'\`
ibmcloud ce jobrun logs -f -r --jobrun \${JOBRUN_NAME} | egrep --line-buffered -v '(^Getting|^OK|^Job run)'

ACCOUNTING_END=\`date +%s\`
echo "Delete jobrun" >> \${LOG}
ibmcloud ce jobrun delete --name \${JOBRUN_NAME} -f >> \${LOG} 2>&1

echo "Delete job" >> \${LOG}
ibmcloud ce job delete --name \${NEW_JOBID} -f >> \${LOG} 2>&1

if test "\${LSB_JOBID}" != ""
then
   # Accounting:
   RUNTIME=\`expr \${ACCOUNTING_END} - \${ACCOUNTING_START}\`
   RESOURCES=\`echo \${CODEENGINE_OPTIONS} | awk '{for(i=1;i<=NF;i++){if(\$i~"-resources"){print \$i}}}' | sed s/"-resources="//g\`
   CORES=\`echo \${RESOURCES} | awk 'BEGIN{FS="x"}{print \$1}'\`
   MEM=\`echo \${RESOURCES} | awk 'BEGIN{FS="x"}{print \$2}'\`
   ARRAY=\`echo \${CODEENGINE_OPTIONS} | awk '{for(i=1;i<=NF;i++){if(\$i~"-array"){print \$i}}}' | sed s/"-array="//g\`
   if test "\${ARRAY}" != ""
   then
      ELEMENTS=\`awk 'BEGIN{arr="'\${ARRAY}'";gsub(/\[|\]/,"",arr);n=split(arr,parts,",");total=0;for(i=1;i<=n;i++){if(index(parts[i],"-")>0){split(parts[i],range,"-");start=range[1];end=range[2];total+=(end-start+1)}else{total+=1}}print"",total}'\`
   else
      ELEMENTS="1"
   fi

   MEMSEC=\`echo \${MEM} \${RUNTIME} \${ELEMENTS} | awk '{printf("%i\n",\$1*\$2*\$3)}'\`
   CPUSEC=\`echo \${CORES} \${RUNTIME} \${ELEMENTS} | awk '{printf("%i\n",\$1*\$2*\$3)}'\`
   PRICE=\`echo \${CPUSEC} \${PRICE_vCPUsec} \${MEMSEC} \${PRICE_GBsec} | awk '{printf("%.8f\n",\$1*\$2+\$3*\$4)}'\`

   echo "\${LSB_JOBID} \${LSB_SUB_USER} \${LSB_QUEUE} \${LSB_PROJECT_NAME} \${CORES} \${MEM} \${RUNTIME} \${ELEMENTS} \${CPUSEC} \${MEMSEC} \${PRICE}" >> ${ACCT}
fi

exit 0
EOF1
chmod 755 /usr/bin/codeengine-starter.sh

cat > /usr/bin/codeengine-control.sh <<EOF1
#!/bin/sh

JOB=\`basename \${LSB_EXEC_DRIVER_ID} | awk 'BEGIN{FS="."}{print \$4}'\`

export IBMCLOUD_API_KEY="${IBMCLOUD_API_KEY}"
export IBMCLOUD_RESOURCE_GROUP="${IBMCLOUD_RESOURCE_GROUP}"
export IBMCLOUD_REGION="${IBMCLOUD_REGION}"

export LOG="${LOG}"

RET=\`ibmcloud plugin list | egrep code-engine\`
if test "\${RET}" = ""
then
   ibmcloud plugin install ce -f >> \${LOG} 2>&1
fi
ibmcloud login -r \${IBMCLOUD_REGION} -q 2>/dev/null | egrep '(Account:|User:)' >> \${LOG} 2>&1
ibmcloud target -r \${IBMCLOUD_REGION} -g \${IBMCLOUD_RESOURCE_GROUP} >> \${LOG} 2>&1

case \$1 in
2|3|9|12|15|1000)
   # Kill job \${JOB}
   PROJECT=\`ibmcloud ce project list | egrep \${IBMCLOUD_REGION} | awk '{print \$1}' | sort | tail -1\`
   ibmcloud ce project select -n \${PROJECT} >> \${LOG} 2>&1
   JOBRUN_NAME=\`ibmcloud ce jobrun list | egrep \${JOB} | egrep task | awk '{print \$1}'\`
   ibmcloud ce jobrun  delete --name \${JOBRUN_NAME} -f >> \${LOG} 2>&1
   ibmcloud ce job delete --name \${JOB} -f >> \${LOG} 2>&1
;;
esac
EOF1
chown lsfadmin:lsfadmin /usr/bin/codeengine-control.sh
chmod 755 /usr/bin/codeengine-control.sh

cat > ${LSF_SERVERDIR}/esub <<EOF1
#!/bin/sh

RED='\e[1;31m'
GREEN='\e[1;32m'
BLUE='\e[1;34m'
OFF='\e[0;0m'

exec 1>&2
if [ "\${LSB_SUB_PARM_FILE}" != "" ] ; then
   . \${LSB_SUB_PARM_FILE}
   if [ "\${LSB_SUB3_APP}" = "codeengine" ]; then
      if [ "\${LSB_SUB_JOB_NAME}" != "" ]; then
         RET=\`echo \${LSB_SUB_JOB_NAME} | fgrep '[' | fgrep ']'\`
         if test "\${RET}" != ""
         then
            ARRAY=\`echo \${LSB_SUB_JOB_NAME} | awk 'BEGIN{FS="["}{print \$2}' | awk 'BEGIN{FS="]"}{printf("-array=%s\n",\$1)}'\`
            PURE_JOBNAME=\`echo \${LSB_SUB_JOB_NAME} | awk 'BEGIN{FS="["}{print \$1}'\`
            echo "LSB_SUB_JOB_NAME=\"\${PURE_JOBNAME}\"" >> \${LSB_SUB_MODIFY_FILE}
            CODEENGINE_OPTIONS="\${CODEENGINE_OPTIONS} \${ARRAY}"
         fi
      fi
      if test "\${CODEENGINE_OPTIONS}" != ""
      then
         echo "CODEENGINE_OPTIONS=\"\${CODEENGINE_OPTIONS}\"" >> \${LSB_SUB_MODIFY_ENVFILE}
      fi
   fi
fi

EOF1
chmod 755 ${LSF_SERVERDIR}/esub

cat > /usr/bin/codeengine-pre.sh <<EOF1
#!/bin/sh

COSBUCKET="${COSBUCKET}"
ACCESS_KEY_ID="${ACCESS_KEY_ID}"
SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}"

DATE=\`date +%Y%m%d_%Hh%Mm%Ss\`
MOUNTPOINT="/tmp/\${BUCKET}_\${DATE}"

if test "\${LSB_JOBID}" != ""
then
   PROJECT="\${LSB_PROJECT_NAME}"
   NEW_JOBID="lsfce-\${LSB_JOBID}"
   LOCALDIR="\${LS_SUBCWD}"
fi

if test "\${SLURM_JOBID}" != ""
then
   PROJECT="\${SLURM_JOB_ACCOUNT}"
   NEW_JOBID="slurm-\${SLURM_JOBID}"
   LOCALDIR="\${SLURM_JOB_WORK_DIR}"
fi

if test "\${PROJECT}" = "with_cos"
then
   mkdir -p \${MOUNTPOINT}

   cat > \${HOME}/.passwd-s3fs <<EOF2
\${ACCESS_KEY_ID}:\${SECRET_ACCESS_KEY}
EOF2
   chmod 600 \${HOME}/.passwd-s3fs

   s3fs \${COSBUCKET} \${MOUNTPOINT} -o passwd_file=\${HOME}/.passwd-s3fs -o url=https://s3.eu-de.cloud-object-storage.appdomain.cloud

   rm -rf \${MOUNTPOINT}/\${NEW_JOBID}
   mkdir -p \${MOUNTPOINT}/\${NEW_JOBID}
   cp /tmp/INPUT.txt \${MOUNTPOINT}/\${NEW_JOBID}
   cp /tmp/INPUT.txt \${LOCALDIR}

   umount \${MOUNTPOINT}
   rm -rf \${MOUNTPOINT}
fi
EOF1
chmod 755 /usr/bin/codeengine-pre.sh

cat > /usr/bin/codeengine-post.sh <<EOF1
#!/bin/sh

COSBUCKET="${COSBUCKET}"
ACCESS_KEY_ID="${ACCESS_KEY_ID}"
SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}"

DATE=\`date +%Y%m%d_%Hh%Mm%Ss\`
MOUNTPOINT="/tmp/\${BUCKET}_\${DATE}"

if test "\${LSB_JOBID}" != ""
then
   PROJECT="\${LSB_PROJECT_NAME}"
   NEW_JOBID="lsfce-\${LSB_JOBID}"
   LOCALDIR="\${LS_SUBCWD}"
fi

if test "\${SLURM_JOBID}" != ""
then
   PROJECT="\${SLURM_JOB_ACCOUNT}"
   NEW_JOBID="slurm-\${SLURM_JOBID}"
   LOCALDIR="\${SLURM_JOB_WORK_DIR}"
fi

if test "\${PROJECT}" = "with_cos"
then
   mkdir -p \${MOUNTPOINT}

   cat > \${HOME}/.passwd-s3fs <<EOF2
\${ACCESS_KEY_ID}:\${SECRET_ACCESS_KEY}
EOF2
   chmod 600 \${HOME}/.passwd-s3fs

   s3fs \${COSBUCKET} \${MOUNTPOINT} -o passwd_file=\${HOME}/.passwd-s3fs -o url=https://s3.eu-de.cloud-object-storage.appdomain.cloud

   cp \${MOUNTPOINT}/\${NEW_JOBID}/OUTPUT*txt \${LOCALDIR}
   rm -rf \${MOUNTPOINT}/\${NEW_JOBID}

   umount \${MOUNTPOINT}
   rm -rf \${MOUNTPOINT}
fi
EOF1
chmod 755 /usr/bin/codeengine-post.sh

cat > /usr/bin/add-volume-mount-to-job.sh <<EOF1
#!/usr/bin/env bash
#*******************************************************************************
# Licensed Materials - Property of IBM
# IBM Cloud Code Engine, 5900-AB0
# © Copyright IBM Corp. 2024
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with IBM Corp.
#*******************************************************************************

# Script to help setting up the volume mount for the batch job definition.

# NOTE: The user must select the Code Engine project before running this script. 
# Usage: add-volume-mount-to-job.sh CE_JOB_NAME MOUNT_NAME MOUNT_PATH


# Check whether all required input params are set
if [[ -z "\$1" || -z "\$2" || -z "\$3" ]]
  then
    echo "One or more arguments are missing"
    echo "Usage: add-volume-mount-to-job.sh CE_JOB_NAME MOUNT_NAME MOUNT_PATH"
    exit 1
fi

set -euo pipefail

# Obtain the input parameters
CE_JOB_NAME=\$1
MOUNT_NAME=\$2
MOUNT_PATH=\$3


echo ""
echo "CE_JOB_NAME: '\$CE_JOB_NAME'"
echo "CE_MOUNT_NAME: '\$MOUNT_NAME'"
echo "CE_MOUNT_PATH: '\$MOUNT_PATH'"
echo ""

VOLUME_NAME=\$1-\$2

# Create the JSON patch

PATCH='[
  {
    "op": "add",
    "path": "/spec/template/volumes",
    "value": [{
      "name": "'\$VOLUME_NAME'",
      "persistentVolumeClaim": {
        "claimName": "'\$MOUNT_NAME'"
      }
    }]
  },
  {
    "op": "add",
    "path": "/spec/template/containers/0/volumeMounts",
    "value": [{
      "name": "'\$VOLUME_NAME'",
      "mountPath": "'\$MOUNT_PATH'"
    }]
  }
]'

# Apply the patch
kubectl patch jobdefinition  \$CE_JOB_NAME --type='json' --patch "\$PATCH"

echo "Patched job '\$CE_JOB_NAME' with volume '\$VOLUME_NAME' mounted at '\$MOUNT_PATH'."
EOF1
chmod 755 /usr/bin/add-volume-mount-to-job.sh

############################################################

echo ${ESC} ""
echo ${ESC} "${BLUE}Create user example scripts${OFF}"
echo ${ESC} "${BLUE}===========================${OFF}"


if test ! -f /tmp/INPUT.txt
then
   tr -dc A-Za-z </dev/urandom  | fold -w 40 | head -n 100 > /tmp/INPUT.txt
   chmod 755 /tmp/INPUT.txt
fi


if test ! -f /tmp/lsf_testjob.sh
then
   cat > /tmp/lsf_testjob.sh <<EOF1
#BSUB -app codeengine
#BSUB -I
#BSUB -J testjob
#BSUB -P with_cos

. /etc/os-release

echo "########################################"
echo
echo "cat /mnt/lsfce-\${LSB_JOBID}/INPUT.txt | sort --ignore-case > /mnt/lsfce-\${LSB_JOBID}/OUTPUT.txt:"
cat /mnt/lsfce-\${LSB_JOBID}/INPUT.txt | sort --ignore-case > /mnt/lsfce-\${LSB_JOBID}/OUTPUT.txt
echo
echo "########################################"
EOF1
fi

if test ! -f /tmp/lsf_testarray.sh
then
   cat > /tmp/lsf_testarray.sh <<EOF1
#BSUB -app codeengine
#BSUB -J arraytest[1-5]
#BSUB -P with_cos

TOTAL=\`cat /mnt/lsfce-\${LSB_JOBID}/INPUT.txt | wc -l\`
STEP_WIDTH=\`expr \${TOTAL} / \${JOB_ARRAY_SIZE}\`
START=\`expr \${JOB_INDEX} \* \${STEP_WIDTH}\`

cat /mnt/lsfce-\${LSB_JOBID}/INPUT.txt | sort --ignore-case | head -\${START} | tail -\${STEP_WIDTH} > /mnt/lsfce-\${LSB_JOBID}/OUTPUT.\${JOB_INDEX}.txt
EOF1

cat > /tmp/lsf_teststdout.sh <<EOF1
#BSUB -app codeengine
#BSUB -I
#BSUB -J teststdout

echo "Run 5 iterations"
CNT=1
while test \${CNT} -le 5
do
   echo Run \${CNT}
   date
   CNT=\`expr \${CNT} + 1\`
   sleep 5
done
EOF1
fi

if test ! -f /tmp/slurm_testjob.sh
then
   cat > /tmp/slurm_testjob.sh <<EOF1
#!/usr/bin/codeengine-starter.sh
#SBATCH --partition LocalQ
#SBATCH --job-name=testjob
#SBATCH --account=with_cos

. /etc/os-release

echo "########################################"
echo
if test "\${LSB_JOBID}" != ""
then
   NEW_JOBID="lsfce-\${LSB_JOBID}"
fi

if test "\${SLURM_JOBID}" != ""
then
   NEW_JOBID="slurm-\${SLURM_JOBID}"
fi

echo "cat /mnt/\${NEW_JOBID}/INPUT.txt | sort --ignore-case > /mnt/\${NEW_JOBID}/OUTPUT.txt:"
cat /mnt/\${NEW_JOBID}/INPUT.txt | sort --ignore-case > /mnt/\${NEW_JOBID}/OUTPUT.txt
echo
echo "########################################"
EOF1
   chmod 755 /tmp/slurm_testjob.sh
fi

if test ! -f /tmp/slurm_teststdout.sh
then
   cat > /tmp/slurm_teststdout.sh <<EOF1

echo "Run 5 iterations"
CNT=1
while test \${CNT} -le 5
do
   echo Run \${CNT}
   date
   CNT=\`expr \${CNT} + 1\`
   sleep 5
done
EOF1
   chmod 755 /tmp/slurm_teststdout.sh
fi

if test ! -f /tmp/slurm_testarray.sh
then
   cat > /tmp/slurm_testarray.sh <<EOF1
#!/usr/bin/codeengine-starter.sh
#SBATCH --partition LocalQ
#SBATCH --job-name=testjob[1-5]
#SBATCH --account=with_cos

if test "\${LSB_JOBID}" != ""
then
   NEW_JOBID="lsfce-\${LSB_JOBID}"
fi

if test "\${SLURM_JOBID}" != ""
then
   NEW_JOBID="slurm-\${SLURM_JOBID}"
fi

TOTAL=\`cat /mnt/\${NEW_JOBID}/INPUT.txt | wc -l\`
STEP_WIDTH=\`expr \${TOTAL} / \${JOB_ARRAY_SIZE}\`
START=\`expr \${JOB_INDEX} \* \${STEP_WIDTH}\`

cat /mnt/\${NEW_JOBID}/INPUT.txt | sort --ignore-case | head -\${START} | tail -\${STEP_WIDTH} > /mnt/\${NEW_JOBID}/OUTPUT.\${JOB_INDEX}.txt

EOF1
   chmod 755 /tmp/slurm_testarray.sh
fi

############################################################

cat <<EOF1

Open a new shell and try:

LSF:
lsid
watch "bjobs -u all -a"
bsub -app codeengine -I "date;hostname;sleep 10"
bsub -app codeengine -I "cat /etc/os-release"
bsub < /tmp/lsf_testjob.sh
bsub < /tmp/lsf_testarray.sh
bsub < /tmp/lsf_teststdout.sh
time bsub -app codeengine -I date

SLURM:
sinfo
watch "scontrol show job | egrep JobState"
srun /usr/bin/codeengine-starter.sh "date;hostname;sleep 10"
srun /usr/bin/codeengine-starter.sh "cat /etc/os-release"
sbatch /tmp/slurm_testjob.sh
sbatch /tmp/slurm_testarray.sh
srun /usr/bin/codeengine-starter.sh /tmp/slurm_teststdout.sh
time srun /usr/bin/codeengine-starter.sh date
EOF1
