#!/bin/sh
# Writes the full install script for version $1 (default 2.0.1) to stdout: the 1.3.5 install script, then
# the part of the 1.3.5 -> $1 upgrade script from "CREATE TYPE postal_code;" onwards. The upgrade script is
# the source of truth; postcode--$1.sql is generated from it (make install-script) and
# `make verify-install-script` fails if the two have drifted apart.
set -e
V=${1:-2.0.1}
cd "$(dirname "$0")/.."
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
