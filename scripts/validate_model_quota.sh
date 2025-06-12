#!/bin/bash

LOCATION=""
MODELS_PARAMETER=""
PARAMETER_FILE="./infra/main.parameters.json"

ALL_REGIONS=('australiaeast' 'eastus' 'eastus2' 'francecentral' 'japaneast' 'norwayeast' 'southindia' 'swedencentral' 'uksouth' 'westus' 'westus3')

# -------------------- Parse Args --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)
      LOCATION="$2"
      shift 2
      ;;
    --models-parameter)
      MODELS_PARAMETER="$2"
      shift 2
      ;;
    *)
      echo "❌ ERROR: Unknown option: $1"
      exit 1
      ;;
  esac
done

# -------------------- Validate Inputs --------------------
MISSING_PARAMS=()
[[ -z "$LOCATION" ]] && MISSING_PARAMS+=("location")
[[ -z "$MODELS_PARAMETER" ]] && MISSING_PARAMS+=("models-parameter")

if [[ ${#MISSING_PARAMS[@]} -ne 0 ]]; then
  echo "❌ ERROR: Missing or invalid parameters: ${MISSING_PARAMS[*]}"
  echo "Usage: $0 --location <LOCATION> --models-parameter <MODELS_PARAMETER>"
  exit 1
fi

# -------------------- Load Models --------------------
MODEL_LIST=$(jq -c ".parameters.$MODELS_PARAMETER.value[]" "$PARAMETER_FILE" 2>/dev/null)
if [[ $? -ne 0 || -z "$MODEL_LIST" ]]; then
  echo "❌ ERROR: Failed to parse '$MODELS_PARAMETER' from $PARAMETER_FILE"
  exit 1
fi

# -------------------- Extract Model Names --------------------
MODEL_NAMES=()
while IFS= read -r model_entry; do
  model_name=$(echo "$model_entry" | jq -r '.name')
  MODEL_NAMES+=("$model_name")
done <<< "$MODEL_LIST"
joined_models=$(IFS=, ; echo "${MODEL_NAMES[*]}")

# -------------------- Print Table Header --------------------
print_table_header() {
  echo ""
  printf "%-15s | %-40s | %-5s | %-5s | %-6s | %-8s \n" "Region" "Model Name" "Limit" "Used" "Avail" "Required"
  printf -- "-------------------------------------------------------------------------------------------------------------\n"
}

# -------------------- Function: Check Region Quota --------------------
check_all_models_in_region() {
  local region="$1"
  local all_ok=true
  local region_rows=()
  local index=1

  while IFS= read -r model_entry; do
    name=$(echo "$model_entry" | jq -r '.name')
    model=$(echo "$model_entry" | jq -r '.model.name')
    type=$(echo "$model_entry" | jq -r '.sku.name')
    capacity=$(echo "$model_entry" | jq -r '.sku.capacity')
    model_type="OpenAI.$type.$model"

    usage=$(az cognitiveservices usage list --location "$region" --query "[?name.value=='$model_type']" --output json 2>/dev/null)

    if [[ -z "$usage" || "$usage" == "[]" ]]; then
      all_ok=false
      break
    fi

    current=$(echo "$usage" | jq -r '.[0].currentValue // 0' | cut -d'.' -f1)
    limit=$(echo "$usage" | jq -r '.[0].limit // 0' | cut -d'.' -f1)
    available=$((limit - current))

    if [[ "$available" -lt "$capacity" ]]; then
      all_ok=false
      break
    fi

    row=$(printf "%-15s | %-40s | %-5s | %-5s | %-6s | %-8s" "$region" "$model_type" "$limit" "$current" "$available" "$capacity")
    region_rows+=("$row")
    ((index++))
  done <<< "$MODEL_LIST"

  if [[ "$all_ok" == true ]]; then
    VALID_REGION_ROWS+=("${region_rows[@]}")
    VALID_REGIONS+=("$region")
    return 0
  else
    return 1
  fi
}

# -------------------- Prompt User --------------------
ask_for_location() {
  echo -e "\nPlease enter any other location from the above table where you want to deploy AI Services:"
  read LOCATION < /dev/tty

  if [[ -z "$LOCATION" ]]; then
    echo "❌ ERROR: No region entered. Exiting."
    exit 1
  fi

  echo "🔍 Rechecking quota in '$LOCATION'..."
  # print_table_header
  check_all_models_in_region "$LOCATION"
  if [[ $? -eq 0 ]]; then
    echo "✅ Sufficient quota found in '$LOCATION'. Proceeding with deployment."
    azd env set AZURE_AISERVICE_LOCATION "$LOCATION"
    echo "➡️  Set AZURE_AISERVICE_LOCATION to '$LOCATION'."
    exit 0
  else
    echo "❌ Insufficient quota in '$LOCATION'."
    ask_for_location
  fi
}

# -------------------- Start Validation --------------------
echo -e "\n🔍 Validating model deployment: $joined_models ..."
echo "🔍 Checking quota in the requested region '$LOCATION'..."
# print_table_header
check_all_models_in_region "$LOCATION"
if [[ $? -eq 0 ]]; then
  # for row in "${VALID_REGION_ROWS[@]}"; do echo "$row"; done
  echo "✅ All models have sufficient quota in region: $LOCATION"
  azd env set AZURE_AISERVICE_LOCATION "$LOCATION"
  exit 0
else
  echo -e "\n⚠️  Insufficient quota in '$LOCATION'. Checking fallback regions..."
fi

# -------------------- Check Fallback Regions --------------------
VALID_REGION_ROWS=()
VALID_REGIONS=()

for region in "${ALL_REGIONS[@]}"; do
  [[ "$region" == "$LOCATION" ]] && continue
  check_all_models_in_region "$region"
done

if [[ ${#VALID_REGION_ROWS[@]} -gt 0 ]]; then
  print_table_header
  for row in "${VALID_REGION_ROWS[@]}"; do echo "$row"; done
  ask_for_location
else
  echo "❌ ERROR: No region found with sufficient quota for all models."
  exit 1
fi
