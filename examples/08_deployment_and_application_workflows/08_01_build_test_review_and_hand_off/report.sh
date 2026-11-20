set -eu

case "$1" in
  build)
    printf 'building report\n'
    { printf 'REPORT\n'; LC_ALL=C tr '[:lower:]' '[:upper:]' < "$2"; } > "$3"
    ;;
  test)
    printf 'testing report\n'
    if [ "${4-}" = wait ]; then
      IFS= read -r answer
      [ "$answer" = continue ]
    fi
    if ! cmp -s "$2" "$3"; then
      printf 'built report differs from expected\n' >&2
      exit 1
    fi
    printf 'passed\n'
    ;;
  *) exit 2 ;;
esac
