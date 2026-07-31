#!/bin/bash

if [[ ! -v PG_SRC ]]; then
  echo 'Do: export PG_SRC=/path/to/postgresql/repository'
  exit 1
fi

# if [[ ! -v PG_BUILD ]]; then
#   echo 'Do: export PG_BUILD=/path/to/postgresql/build'
#   exit 1
# fi

tap_tests=$(find ./t/ -maxdepth 1 -type f | grep -oP "\S+(.pl|.pm)")

for tap_test in $tap_tests; do
  tap_test_name=$(basename $tap_test)
  unlink "$PG_SRC/src/bin/pg_rewind/t/$tap_test_name"
done
