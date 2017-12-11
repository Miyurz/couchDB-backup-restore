#!/usr/bin/env bash

set -eou pipefail

#get list of all databases
curl http://localhost:5984/_all_dbs




#get couchdb service status
service couchdb status
