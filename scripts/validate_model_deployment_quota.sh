#!/bin/bash

SUBSCRIPTION_ID=""
LOCATION=""
MODELS_PARAMETER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --SubscriptionId)
      SUBSCRIPTION_ID="$2"
      shift 2
      ;;
    --Location)
      LOCATION="$2"
      shift 2
      ;;
    --ModelsParameter)
      MODELS_PARAMETER="$2"
      shift 2
      ;;
    *)
      echo "❌ ERROR: Unknown option: $1"
      exit 1
      ;;
  esac
done

AIFOUNDRY_NAME="${AZURE_AIFOUNDRY_NAME}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"

# Validate required parameters
MISSING_PARAMS=()
[[ -z "$SUBSCRIPTION_ID" ]] && MISSING_PARAMS+=("SubscriptionId")
[[ -z "$LOCATION" ]] && MISSING_PARAMS+=("Location")
[[ -z "$MODELS_PARAMETER" ]] && MISSING_PARAMS+=("ModelsParameter")

if [[ ${#MISSING_PARAMS[@]} -ne 0 ]]; then
  echo "❌ ERROR: Missing required parameters: ${MISSING_PARAMS[*]}"
  echo "Usage: $0 --SubscriptionId <SUBSCRIPTION_ID> --Location <LOCATION> --ModelsParameter <MODELS_PARAMETER>"
  exit 1
fi

# Load model definitions
aiModelDeployments=$(jq -c ".parameters.$MODELS_PARAMETER.value[]" ./infra/main.parameters.json)
if [[ $? -ne 0 || -z "$aiModelDeployments" ]]; then
  echo "❌ ERROR: Failed to parse main.parameters.json or missing '$MODELS_PARAMETER'"
  exit 1
fi

# Set subscription
az account set --subscription "$SUBSCRIPTION_ID"
echo "🎯 Active Subscription: $(az account show --query '[name, id]' --output tsv)"

# Try to discover AI Foundry name if not set
if [[ -z "$AIFOUNDRY_NAME" && -n "$RESOURCE_GROUP" ]]; then
  AIFOUNDRY_NAME=$(az cognitiveservices account list --resource-group "$RESOURCE_GROUP" \
    --query "sort_by([?kind=='AIServices'], &name)[0].name" -o tsv 2>/dev/null)
fi

# Check for existing deployments
if [[ -n "$AIFOUNDRY_NAME" && -n "$RESOURCE_GROUP" ]]; then
  existing=$(az cognitiveservices account show --name "$AIFOUNDRY_NAME" \
    --resource-group "$RESOURCE_GROUP" --query "name" --output tsv 2>/dev/null)

  if [[ -n "$existing" ]]; then
    azd env set AZURE_AIFOUNDRY_NAME "$existing" > /dev/null

    existing_deployments=$(az cognitiveservices account deployment list \
      --name "$AIFOUNDRY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --query "[].name" --output tsv 2>/dev/null)

    required_models=$(jq -r ".parameters.$MODELS_PARAMETER.value[].name" ./infra/main.parameters.json)

    missing_models=()
    for model in $required_models; do
      if ! grep -q -w "$model" <<< "$existing_deployments"; then
        missing_models+=("$model")
      fi
    done

    if [[ ${#missing_models[@]} -eq 0 ]]; then
      echo "ℹ️ AI Foundry '$AIFOUNDRY_NAME' exists and all required model deployments are already provisioned."
      echo "⏭️ Skipping quota validation."
      exit 0
    else
      echo "🔍 AI Foundry exists, but the following model deployments are missing: ${missing_models[*]}"
      echo "➡️ Proceeding with quota validation for missing models..."
    fi
  fi
fi

# Call the new script for region-wide quota validation of all models
./scripts/validate_model_quota.sh --location "$LOCATION" --models-parameter "$MODELS_PARAMETER"
exit_code=$?

if [[ $exit_code -ne 0 ]]; then
  echo "❌ ERROR: Quota validation failed for one or more models."
  exit 1
else
  echo "✅ All model deployments passed quota validation successfully."
  exit 0
fi
