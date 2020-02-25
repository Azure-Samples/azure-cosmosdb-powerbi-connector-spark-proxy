#!/bin/bash

# Strict mode, fail on any error
set -euo pipefail

on_error() {
    set +e
    echo "There was an error, execution halted" >&2
    echo "Error at line $1"
    exit 1
}

trap 'on_error $LINENO' ERR

export PREFIX=''
export LOCATION="eastus"

usage() { 
    echo "Usage: $0 -d <deployment-name> [-l <location>]"
    echo "-d: The name for your deployment. This will be the resource group name and the prefix for your resource names."
    echo "-l: Where to create the resources. Default=$LOCATION"
    exit 1; 
}

# Initialize parameters specified from command line
while getopts ":d:l:" arg; do
	case "${arg}" in
		d)
			PREFIX=${OPTARG}
			;;
		l)
			LOCATION=${OPTARG}
			;;
		esac
done
shift $((OPTIND-1))

if [[ -z "$PREFIX" ]]; then
	echo "Enter a name for this deployment."
	usage
fi

# Set service levels
export COSMOSDB_RU=1000
export DATABRICKS_NODETYPE=Standard_DS3_v2
export DATABRICKS_WORKERS=2
export DATABRICKS_AUTOTERMINATE_MINS=300
export DATABRICKS_SPARK_VERSION=6.2.x-scala2.11

export RESOURCE_GROUP=$PREFIX

export LOG_FILE="create-solution-log_`date '+%Y%m%d%H%M%S'`.txt"

echo "Checking pre-requisites..."

source ./assert/has-local-az.sh
source ./assert/has-local-jq.sh
source ./assert/has-local-databrickscli.sh

echo
echo "Cosmos DB PowerBI Connector Proxy Solution Deployment"
echo "====================================================="
echo

echo "Configuration: "
echo ". Resource Group  => $RESOURCE_GROUP"
echo ". Region          => $LOCATION"
echo ". Databricks      => VM: $DATABRICKS_NODETYPE, Workers: $DATABRICKS_WORKERS"
echo ". CosmosDB        => RU: $COSMOSDB_RU"
echo

echo "Deployment started..."
echo

echo "***** Creating Resource Group"
    az group create -n $RESOURCE_GROUP -l $LOCATION \
    -o tsv >> $LOG_FILE
echo

echo "***** Setting up Cosmos DB"

    export COSMOSDB_SERVER_NAME=$PREFIX"cosmosdb" 
    export COSMOSDB_DATABASE_NAME="db"
    export COSMOSDB_COLLECTION_NAME="coll"

    source create-cosmosdb.sh
echo

echo "***** Setting up Databricks"

    export ADB_WORKSPACE=$PREFIX"databricks" 
    export ADB_TOKEN_KEYVAULT=$PREFIX"kv" #NB AKV names are limited to 24 characters
    
    source create-databricks.sh
echo

echo "***** Done with all deployments"
echo "To continue with this sample navigate to https://github.com/jcocchi/CosmosDBPowerBISparkProxy#visualize-data-with-power-bi and follow the instructions."
