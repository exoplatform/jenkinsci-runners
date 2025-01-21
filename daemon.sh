#!/bin/bash -u
echo "Forwarding SSH Port to Jenkins agent"
ssh-keygen -y -f ~/.ssh/id* >> ~/.ssh/authorized_keys
chmod 0600 ~/.ssh/authorized_keys
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -g -N ${AGENT_HOST} -R ${AGENT_FORWARD_PORT}:localhost:22 &
SSH_PID=$!
MVN_PID_FILE=/tmp/.mvnpid
trap "kill -9 ${SSH_PID}" EXIT
echo "Agent Connected"
echo "Waiting for maven execution..."
count=0
try=${MAVEN_WAIT_TIMEOUT:-300}
while [ $count -lt $try ] && ([ ! -f "${MVN_PID_FILE}" ] || ! pgrep -P $(cat "${MVN_PID_FILE}")); do
    sleep 5
    count=$(( $count + 1 ))
    echo "Retry ($count/$try): maven is not yet started!"
done
if [ $count -ge $try ]; then 
  echo "Error! Cound not build maven project! Abort"
  exit 1
fi
MVN_PID=$(cat ${MVN_PID_FILE})
while kill -0 ${MVN_PID} &>/dev/null; do 
  sleep 5 
  echo "OK Maven is running, Wrapper PID=${MVN_PID}"
done
echo "Maven build is finished! Stopping ssh agent..."
sleep 30 # wait for jenkins to close ssh connection and retrieves junit report files
kill -9 ${SSH_PID}
exit 0