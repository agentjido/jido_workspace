#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
    printf 'ready\n'
    while IFS= read -r request; do
        case "$request" in
            report) cat report.txt ;;
            quit) printf 'bye\n'; exit 0 ;;
            *) printf 'unknown request\n' ;;
        esac
    done
    exit 0
fi

chmod 700 "$0"
exec /usr/bin/nc -lk -s 127.0.0.1 -p "$1" -e "./$0"
