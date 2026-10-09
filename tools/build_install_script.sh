#!/bin/sh
# Writes the full install script for version $1 (default 2.1.0) to stdout.
#   2.0.x: the 1.3.5 install script, then the part of the 1.3.5 -> $1 upgrade script from "CREATE TYPE postal_code;"
#   2.1.0: the 2.0.1 install script, then the 2.0.1 -> 2.1.0 upgrade script
# The upgrade script is the source of truth; postcode--$1.sql is generated from it (make install-script) and
# `make verify-install-script` fails if the two have drifted apart.
set -e
V=${1:-2.1.0}
cd "$(dirname "$0")/.."
if [ -f "postcode--1.3.5--$V.sql" ]; then
   L=$(grep -n "^CREATE TYPE postal_code;" postcode--1.3.5--$V.sql | cut -d: -f1)
   {
      cat postcode--1.3.5.sql
      echo
      echo
      echo "-- postal_code additions ($V) -- see postcode--1.3.5--$V.sql for the standalone"
      echo "-- upgrade version of this section, with its own full explanatory comment."
      echo
      tail -n +"$L" postcode--1.3.5--$V.sql
   }
elif [ -f "postcode--2.0.1--$V.sql" ]; then
   {
      cat postcode--2.0.1.sql
      echo
      echo
      echo "-- additions in $V -- see postcode--2.0.1--$V.sql for the standalone upgrade version of this section."
      echo
      cat postcode--2.0.1--$V.sql
   }
else
   echo "no upgrade script found for $V" >&2
   exit 1
fi
