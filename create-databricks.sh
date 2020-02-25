#!/bin/bash

# Strict mode, fail on any error
set -euo pipefail

if [ -n "${DATABRICKS_TOKEN:-}" ]; then

  echo 'Not creating Databricks workspace. Using environment DATABRICKS_TOKEN setting'

  if [ -z "${DATABRICKS_HOST:-}" ]; then
    export DATABRICKS_HOST="https://$LOCATION.azuredatabricks.net"
  fi

else

if ! az resource show -g $RESOURCE_GROUP --resource-type Microsoft.Databricks/workspaces -n $ADB_WORKSPACE -o none 2>/dev/null; then
echo 'creating databricks workspace'
echo ". name: $ADB_WORKSPACE"
az group deployment create \
  --name $ADB_WORKSPACE \
  --resource-group $RESOURCE_GROUP \
  --template-file arm-templates/databricks-arm-template.json \
  --parameters \
  workspaceName=$ADB_WORKSPACE \
  location=$LOCATION \
  tier=standard \
  -o tsv >> $LOG_FILE
fi

databricks_metainfo=$(az resource show -g $RESOURCE_GROUP --resource-type Microsoft.Databricks/workspaces -n $ADB_WORKSPACE -o json)

echo 'creating Key Vault to store Databricks PAT token'
az keyvault create -g $RESOURCE_GROUP -n $ADB_TOKEN_KEYVAULT -o tsv >> $LOG_FILE

echo 'checking PAT token secret presence in Key Vault'
databricks_token_secret_name="DATABRICKS-TOKEN"
pat_token_secret=$(az keyvault secret list --vault-name $ADB_TOKEN_KEYVAULT --query "[?ends_with(id, '/$databricks_token_secret_name')].id" -o tsv)
if [[ -z "$pat_token_secret" ]]; then
  echo 'PAT token secret not present. Creating dummy entry for user to fill in manually'
  az keyvault secret set --vault-name $ADB_TOKEN_KEYVAULT -n "$databricks_token_secret_name" --file /dev/null -o tsv >> $LOG_FILE
fi

echo 'checking PAT token presence in Key Vault'
pat_token=$(az keyvault secret show --vault-name $ADB_TOKEN_KEYVAULT -n "$databricks_token_secret_name" --query value -o tsv)

if [[ -z "$pat_token" ]]; then
  echo 'PAT token not present. Requesting user to fill in manually'
  databricks_login_url=$(jq -r '"https://" + .location + ".azuredatabricks.net/aad/auth?has=&Workspace=" + .id + "&WorkspaceResourceGroupUri="+ .properties.managedResourceGroupId' <<<"$databricks_metainfo")

  kv_info=$(az resource show -g $RESOURCE_GROUP --resource-type Microsoft.KeyVault/vaults -n $ADB_TOKEN_KEYVAULT -o json)
  kv_secrets_url=$(jq -r '"https://portal.azure.com/#@" + .properties.tenantId + "/resource" + .id + "/secrets"' <<<$kv_info)

  cat <<EOM
  Please manually create a Databricks PAT token and register it into the Key Vault as follows,
  then this script will resume.

  - Navigate to:
      $databricks_login_url
    Create a PAT token and copy it to the clipboard:
      https://docs.azuredatabricks.net/api/latest/authentication.html#generate-a-token
  - Navigate to:
      $kv_secrets_url
    Click $databricks_token_secret_name
    Click "+ New Version"
    As value, enter the PAT token you copied
    Click Create
  - The script will wait for the PAT to be copied into the Key Vault

EOM
  
  echo 'waiting for PAT (polling every 5 secs)...'
  while : ; do
    pat_token=$(az keyvault secret show --vault-name "$ADB_TOKEN_KEYVAULT" --name "$databricks_token_secret_name" --query value -o tsv | grep dapi || true)	
    if [ ! -z "$pat_token" ]; then break; fi
	  sleep 5
  done
  echo 'PAT detected'
fi

# Databricks CLI automatically picks up configuration from these two environment variables.
export DATABRICKS_HOST=$(jq -r '"https://" + .location + ".azuredatabricks.net"' <<<"$databricks_metainfo")
export DATABRICKS_TOKEN="$pat_token"

fi
echo 'checking Databricks secrets scope exists'
declare SECRETS_SCOPE=$(databricks secrets list-scopes --output JSON | jq -e ".scopes[]? | select (.name == \"MAIN\") | .name") &>/dev/null
if [ -z "$SECRETS_SCOPE" ]; then
  echo 'creating Databricks secrets scope'
  databricks secrets create-scope --scope "MAIN" --initial-manage-principal "users"
fi

echo 'writing Databricks secrets'
COSMOSDB_MASTER_KEY=$(az cosmosdb keys list -g $RESOURCE_GROUP -n $COSMOSDB_SERVER_NAME --query "primaryMasterKey" -o tsv)
databricks secrets put --scope "MAIN" --key "cosmos-key" --string-value "$COSMOSDB_MASTER_KEY"

echo 'importing notebooks'
databricks workspace import_dir notebooks /Shared/cosmosdb-powerbi --overwrite

cluster_def=$(
    cat <<JSON
{
    "cluster_name": "powerbi-proxy-cluster",
    "spark_version": "$DATABRICKS_SPARK_VERSION",
    "node_type_id": "$DATABRICKS_NODETYPE",
    "autoscale" : {
        "min_workers": 1,
        "max_workers": 4
    },
    "spark_env_vars": {
        "PYSPARK_PYTHON": "/databricks/python3/bin/python3"
    },
    "autotermination_minutes": $DATABRICKS_AUTOTERMINATE_MINS
}
JSON
)

echo "creating a cluster... this will take a few minutes then this script will resume"
cluster_id=$(databricks clusters create --json "$cluster_def" | jq .cluster_id)
cluster_status=$(databricks clusters list | awk '{print $3}' | head -n 1) 

# Poll to see when the cluster is up and running before continuing
while [ "$cluster_status" != "RUNNING" ]; do
    sleep 5s
    cluster_status=$(databricks clusters list | awk '{print $3}' | head -n 1)
done

echo "cluster is up and running"

for notebook in notebooks/*.scala; do

    notebook_name=$(basename $notebook .scala)
    notebook_path=/Shared/cosmosdb-powerbi/$notebook_name

    job_def=$(
        cat <<JSON
    {
        "name": "Load data from Cosmos DB",
        "existing_cluster_id": $cluster_id,
        "libraries": [
            {
                "maven": {
                    "coordinates": "com.microsoft.azure:azure-cosmosdb-spark_2.4.0_2.11:1.4.0"
                }
            }
        ],
        "notebook_task": {
            "notebook_path": "$notebook_path",
            "base_parameters": {
                "cosmos-endpoint": "$COSMOSDB_SERVER_NAME",
                "cosmos-database": "$COSMOSDB_DATABASE_NAME",
                "cosmos-collection": "$COSMOSDB_COLLECTION_NAME"
            }
        }
    }
JSON
    )

    echo "job_def: $job_def"

    echo "starting Databricks notebook job for $notebook"
    job_id=$(databricks jobs create --json "$job_def" | jq .job_id)

    run=$(databricks jobs run-now --job-id $job_id)

    # Echo job web page URL to task output to facilitate debugging
    run_id=$(echo $run | jq .run_id)
    databricks runs get --run-id "$run_id" | jq -r .run_page_url >> $LOG_FILE
done # for each notebook