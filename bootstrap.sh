#!/bin/bash -x

echo Starting

: ${HADOOP_PREFIX:=/usr/local/hadoop}

echo Using ${HADOOP_HOME} as HADOOP_HOME

. $HADOOP_HOME/etc/hadoop/hadoop-env.sh

# ------------------------------------------------------
# Directory to find config artifacts
# ------------------------------------------------------

CONFIG_DIR="/tmp/hadoop-config"

# ------------------------------------------------------
# Copy config files from volume mount
# ------------------------------------------------------

for f in slaves core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml; do
  if [[ -e ${CONFIG_DIR}/$f ]]; then
    cp ${CONFIG_DIR}/$f $HADOOP_HOME/etc/hadoop/$f
  else
    echo "ERROR: Could not find $f in $CONFIG_DIR"
    exit 1
  fi
done

# ------------------------------------------------------
# installing libraries if any
# (resource urls added comma separated to the ACP system variable)
# ------------------------------------------------------
cd $HADOOP_HOME/share/hadoop/common ; for cp in ${ACP//,/ }; do  echo == $cp; curl -LO $cp ; done; cd -

# ------------------------------------------------------
# Start NAMENODE
# ------------------------------------------------------
if [[ "${HADOOP_ROLE}" == "namenode" ]] || [[ "${HOSTNAME}" =~ "hdfs-nn" ]]; then
  # sed command changing REPLACEME in $HADOOP_HOME/etc/hadoop/hdfs-site.xml to actual port numbers
  sed -i "s/EXTERNAL_HTTP_PORT_REPLACEME/9864/" $HADOOP_HOME/etc/hadoop/hdfs-site.xml
  sed -i "s/EXTERNAL_DATA_PORT_REPLACEME/9866/" $HADOOP_HOME/etc/hadoop/hdfs-site.xml

  mkdir -p /root/hdfs/namenode
  if [ ! -f /root/hdfs/namenode/formated ]; then
    # Only format if necessary
    $HADOOP_HOME/bin/hdfs namenode -format -force -nonInteractive && echo 1 > /root/hdfs/namenode/formated
  fi
  $HADOOP_HOME/bin/hdfs --loglevel INFO --daemon start namenode
fi

# ------------------------------------------------------
# Start DATA NODE
# ------------------------------------------------------
if [[ "${HADOOP_ROLE}" == "datanode" ]] || [[ "${HOSTNAME}" =~ "hdfs-dn" ]]; then
  # Split hostname at "-" into an array
  # Example hostname: hadoop-hadoop-hdfs-dn-0
  # HOSTNAME_ARR=(${HOSTNAME//-/ })
  # Add instance number to start of external port ranges
  # EXTERNAL_HTTP_PORT=$((51000 + ${HOSTNAME_ARR[4]}))
  # EXTERNAL_DATA_PORT=$((50500 + ${HOSTNAME_ARR[4]}))
  EXTERNAL_HTTP_PORT=$((51000 + ${HOSTNAME##*-}))
  EXTERNAL_DATA_PORT=$((50500 + ${HOSTNAME##*-}))

  # sed command changing REPLACEME in $HADOOP_HOME/etc/hadoop/hdfs-site.xml to actual port numbers
  sed -i "s/EXTERNAL_HTTP_PORT_REPLACEME/${EXTERNAL_HTTP_PORT}/" $HADOOP_HOME/etc/hadoop/hdfs-site.xml
  sed -i "s/EXTERNAL_DATA_PORT_REPLACEME/${EXTERNAL_DATA_PORT}/" $HADOOP_HOME/etc/hadoop/hdfs-site.xml

  mkdir -p /root/hdfs/datanode

  #  Wait (with timeout) for namenode
  TMP_URL="http://hadoop-hadoop-hdfs-nn:9870"
  if timeout 5m bash -c "until curl -sf $TMP_URL; do echo Waiting for $TMP_URL; sleep 5; done"; then
    $HADOOP_HOME/bin/hdfs --loglevel INFO --daemon start datanode
  else 
    echo "$0: Timeout waiting for $TMP_URL, exiting."
    exit 1
  fi

fi

# ------------------------------------------------------
# Start RESOURCE MANAGER and PROXY SERVER as daemons
# ------------------------------------------------------
if [[ "${YARN_ROLE}" == "resourcemanager" ]] || [[ "${HOSTNAME}" =~ "yarn-rm" ]]; then
  $HADOOP_HOME/bin/yarn --loglevel INFO --daemon start resourcemanager 
  $HADOOP_HOME/bin/yarn --loglevel INFO --daemon start proxyserver
fi

# ------------------------------------------------------
# Start NODE MANAGER
# ------------------------------------------------------
if [[ "${YARN_ROLE}" == "nodemanager" ]] || [[ "${HOSTNAME}" =~ "yarn-nm" ]]; then
  sed -i '/<\/configuration>/d' $HADOOP_HOME/etc/hadoop/yarn-site.xml
  cat >> $HADOOP_HOME/etc/hadoop/yarn-site.xml <<- EOM
  <property>
    <name>yarn.nodemanager.resource.memory-mb</name>
    <value>-2048</value>
  </property>

  <property>
    <name>yarn.nodemanager.resource.cpu-vcores</name>
    <value>-2</value>
  </property>
EOM

  echo '</configuration>' >> $HADOOP_HOME/etc/hadoop/yarn-site.xml

  # Wait with timeout for resourcemanager
  TMP_URL="http://hadoop-hadoop-yarn-rm:8088/ws/v1/cluster/info"
  if timeout 5m bash -c "until curl -sf $TMP_URL; do echo Waiting for $TMP_URL; sleep 5; done"; then
    $HADOOP_HOME/bin/yarn nodemanager --loglevel INFO
  else 
    echo "$0: Timeout waiting for $TMP_URL, exiting."
    exit 1
  fi

fi

# ------------------------------------------------------
# Tail logfiles for daemonized workloads (parameter -d)
# ------------------------------------------------------
if [[ $1 == "-d" ]]; then
  until find ${HADOOP_HOME}/logs -mmin -1 | egrep -q '.*'; echo "`date`: Waiting for logs..." ; do sleep 2 ; done
  tail -F ${HADOOP_HOME}/logs/* &
  while true; do sleep 1000; done
fi

# ------------------------------------------------------
# Start bash if requested (parameter -bash)
# ------------------------------------------------------
if [[ $1 == "-bash" ]]; then
  /bin/bash
fi