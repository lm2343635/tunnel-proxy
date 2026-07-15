#!/bin/bash
# SSH_ASKPASS helper. ssh runs this (with SSH_ASKPASS_REQUIRE=force) whenever it
# needs a password or key passphrase, passing the prompt text as $1. We simply
# echo the secret the app injected via TP_ASKPASS_SECRET.
#
# The secret is passed through the environment (never on a command line, so it
# doesn't show in `ps`). The app sets it per-connection and clears it after.
printf '%s\n' "${TP_ASKPASS_SECRET}"
