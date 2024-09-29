#!/bin/bash -eu
rsync -q -aP -e 'ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR' ${AGENT_HOST}:.gpg.key $HOME/.gpg.key 
/usr/bin/gpg --batch --pinentry-mode=loopback --no-tty --passphrase "${GPG_PASSPHRASE}" --trust-model always --yes --import $HOME/.gpg.key &>/dev/null
# Initialize trustdb
/usr/bin/gpg --list-keys &>/dev/null
rm -v $HOME/.gpg.key