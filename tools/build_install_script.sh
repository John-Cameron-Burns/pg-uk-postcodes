#!/bin/sh
# Writes the full 2.0.0 install script to stdout: the 1.3.5 install script, then the part of the
# 1.3.5 -> 2.0.0 upgrade script from "CREATE TYPE postal_code;" onwards. The upgrade script is the
# source of truth; postcode--2.0.0.sql is generated from it (make install-script) and
# `make verify-install-script` fails if the two have drifted apart.
set -e
cd "$(dirname "$0")/.."
L=$(grep -n "^CREATE TYPE postal_code;" postcode--1.3.5--2.0.0.sql | cut -d: -f1)
{
   cat postcode--1.3.5.sql
   echo
   echo
   echo "-- postal_code additions (2.0.0) -- see postcode--1.3.5--2.0.0.sql for the standalone"
   echo "-- upgrade version of this section, with its own full explanatory comment."
   echo
   tail -n +"$L" postcode--1.3.5--2.0.0.sql
}
