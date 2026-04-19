#!/bin/sh
# Alternative to viking.pin: any script that prints the PIN to stdout.
# In real life this would shell out to pass / 1Password / Keychain / gpg / age:
#   exec pass show elster/main
#   exec security find-generic-password -s elster -w
#   exec secret-tool lookup app elster
echo 123456
