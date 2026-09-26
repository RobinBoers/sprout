#!/bin/sh
# Send one line to sprout's control socket and print response, if any.

sprout_socket_send() {
	if swallow readlink -f "$(command -v nc)" | grep -q busybox; then
		# BusyBox nc (Alpine) has no -U flag, it takes a "local:PATH"
		# pseudo-hostname plus a (unused, but required) port positional.
		printf '%s\n' "$2" | nc "local:$1" 0
	else
		printf '%s\n' "$2" | nc -U "$1"
	fi
}