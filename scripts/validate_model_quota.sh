#!/bin/bash

LOCATION=""
MODEL=""
DEPLOYMENT_TYPE="Standard"
CAPACITY=0
RECOMMENDED_TOKENS=200

MODELS_CSV=""
CAPACITIES_CSV=""
TYPES_CSV=""

ALL_REGIONS=('australiaeast' 'eastus' 'eastus2' 'francecentral' 'japaneast' 'norwayeast' 'southindia' 'swedencentral' 'uksouth' 'westus' 'westus3')

# -------------------- Parse Args --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --capacity)
      CAPACITY="$2"
      shift 2
      ;;
    --deployment-type)
      DEPLOYMENT_TYPE="$2"
      shift 2
      ;;
    --location)
      LOCATION="$2"
      shift 2
      ;;
    --models)
      MODELS_CSV="$2"
      shift 2
      ;;
    --capacities)
      CAPACITIES_CSV="$2"
      shift 2
      ;;
    --types)
      TYPES_CSV="$2"
      shift 2
      ;;
    *)
      echo "❌ ERROR: Unknown option: $1"
      exit 1
      ;;
  esac
done

# -------------------- Multi-model Combined Mode --------------------
if [[ -n "$MODELS_CSV" ]]; then
  IFS=',' read -ra MODELS <<< "$MODELS_CSV"
  IFS=',' read -ra CAPACITIES <<< "$CAPACITIES_CSV"
  IFS=',' read -ra DEPLOYMENT_TYPES <<< "$TYPES_CSV"

  if [[ ${#MODELS[@]} -ne ${#CAPACITIES[@]} || ${#MODELS[@]} -ne ${#DEPLOYMENT_TYPES[@]} ]]; then
    echo "❌ ERROR: Lengths of models, capacities, and types must match."
    exit 1
  fi

  echo ""
  echo "🔍 Validating model deployment: ${MODELS[*]} ..."
  echo "🔍 Checking quota in the requested region '$LOCATION' for the Model '${MODELS[*]}'..."

  declare -A REGION_MODEL_DATA
  declare -A REGION_MODEL_AVAIL
  RECOMMENDED_REGIONS=()
  ALL_GOOD_REGIONS=()

  for region in "${ALL_REGIONS[@]}"; do
    all_models_ok=true
    for i in "${!MODELS[@]}"; do
      model="${MODELS[$i]}"
      cap="${CAPACITIES[$i]}"
      dtype="${DEPLOYMENT_TYPES[$i]}"
      mtype="OpenAI.$dtype.$model"

      output=$(az cognitiveservices usage list --location "$region" --query "[?name.value=='$mtype']" -o json 2>/dev/null)
      [[ -z "$output" || "$output" == "[]" ]] && continue

      used=$(echo "$output" | jq -r '.[0].currentValue // 0' | cut -d'.' -f1)
      limit=$(echo "$output" | jq -r '.[0].limit // 0' | cut -d'.' -f1)
      avail=$((limit - used))

      key="$region|$model"
      REGION_MODEL_DATA["$key"]="$limit|$used|$avail"
      REGION_MODEL_AVAIL["$key"]=$avail

      [[ "$avail" -lt "$cap" ]] && all_models_ok=false
    done

    if [[ "$all_models_ok" == true ]]; then
      ALL_GOOD_REGIONS+=("$region")

      all_models_recommended=true
      for i in "${!MODELS[@]}"; do
        avail=${REGION_MODEL_AVAIL["$region|${MODELS[$i]}"]}
        [[ "$avail" -lt "$RECOMMENDED_TOKENS" ]] && all_models_recommended=false
      done
      [[ "$all_models_recommended" == true ]] && RECOMMENDED_REGIONS+=("$region")
    fi
  done

  echo ""
  printf "%-5s | %-16s | %-40s | %-6s | %-6s | %-9s\n" "No." "Region" "Model Name" "Limit" "Used" "Available"
  printf -- "---------------------------------------------------------------------------------------------\n"

index=1
for region in "${ALL_GOOD_REGIONS[@]}"; do
  for i in "${!MODELS[@]}"; do
    model="${MODELS[$i]}"
    key="$region|$model"
    if [[ -n "${REGION_MODEL_DATA[$key]}" ]]; then
      IFS='|' read -r limit used avail <<< "${REGION_MODEL_DATA[$key]}"
      mtype="OpenAI.${DEPLOYMENT_TYPES[$i]}.$model"
      printf "| %-3s | %-16s | %-40s | %-6s | %-6s | %-9s |\n" "$index" "$region" "$mtype" "$limit" "$used" "$avail"
    fi
  done
  ((index++))
done

  printf -- "-------------------------------------------------------------------------------------------------------------\n"

  # Recommendations
  if [[ ${#RECOMMENDED_REGIONS[@]} -gt 0 ]]; then
    echo -e "\nℹ️  Recommended regions (≥ $RECOMMENDED_TOKENS tokens available for all models): ${RECOMMENDED_REGIONS[*]}"
    echo "👉 It's advisable to deploy in one of these regions for optimal app performance."
  else
    echo -e "\n⚠️  No region has ≥ $RECOMMENDED_TOKENS tokens available for all models. Proceed with caution."
  fi

  echo -e "\nPlease enter any region from the table above to deploy AI Services:"
  read LOCATION < /dev/tty
  echo "🔍 Validating chosen region '$LOCATION'..."

  is_valid=true
  for i in "${!MODELS[@]}"; do
    model="${MODELS[$i]}"
    cap="${CAPACITIES[$i]}"
    avail=${REGION_MODEL_AVAIL["$LOCATION|$model"]}
    if [[ -z "$avail" || "$avail" -lt "$cap" ]]; then
      echo "❌ Insufficient quota for model '$model' in '$LOCATION'. Required: $cap, Available: ${avail:-0}"
      is_valid=false
    fi
  done

  if [[ "$is_valid" == true ]]; then
    echo "✅ All models have sufficient quota in '$LOCATION'."
    azd env set AZURE_AISERVICE_LOCATION "$LOCATION"
    echo "➡️  Set AZURE_AISERVICE_LOCATION to '$LOCATION'."
    exit 0
  else
    echo "❌ Deployment failed due to insufficient quota for one or more models."
    exit 1
  fi
fi

# -------------------- Original Single Model Logic --------------------
MISSING_PARAMS=()
[[ -z "$LOCATION" ]] && MISSING_PARAMS+=("location")
[[ -z "$MODEL" ]] && MISSING_PARAMS+=("model")
[[ "$CAPACITY" -le 0 ]] && MISSING_PARAMS+=("capacity")

if [[ ${#MISSING_PARAMS[@]} -ne 0 ]]; then
  echo "❌ ERROR: Missing or invalid parameters: ${MISSING_PARAMS[*]}"
  echo "Usage: $0 --location <LOCATION> --model <MODEL> --capacity <CAPACITY> [--deployment-type <DEPLOYMENT_TYPE>]"
  exit 1
fi

if [[ "$DEPLOYMENT_TYPE" != "Standard" && "$DEPLOYMENT_TYPE" != "GlobalStandard" ]]; then
  echo "❌ ERROR: Invalid deployment type: $DEPLOYMENT_TYPE. Allowed values: 'Standard', 'GlobalStandard'."
  exit 1
fi

MODEL_TYPE="OpenAI.$DEPLOYMENT_TYPE.$MODEL"
ALL_RESULTS=()
FALLBACK_RESULTS=()
RECOMMENDED_REGIONS=()
NOT_RECOMMENDED_REGIONS=()

ROW_NO=1

# Print validating message only once
echo "🔍 Checking quota in the requested region '$LOCATION' for the Model '$MODEL'..."

# -------------------- Function: Check Quota --------------------
check_quota() {
  local region="$1"
  local output
  output=$(az cognitiveservices usage list --location "$region" --query "[?name.value=='$MODEL_TYPE']" --output json 2>/dev/null)

  if [[ -z "$output" || "$output" == "[]" ]]; then
    return 2  # No data
  fi

  local CURRENT_VALUE
  local LIMIT
  CURRENT_VALUE=$(echo "$output" | jq -r '.[0].currentValue // 0' | cut -d'.' -f1)
  LIMIT=$(echo "$output" | jq -r '.[0].limit // 0' | cut -d'.' -f1)
  local AVAILABLE=$((LIMIT - CURRENT_VALUE))

  ALL_RESULTS+=("$region|$LIMIT|$CURRENT_VALUE|$AVAILABLE")

  if [[ "$AVAILABLE" -ge "$RECOMMENDED_TOKENS" ]]; then
    RECOMMENDED_REGIONS+=("$region")
  else
    NOT_RECOMMENDED_REGIONS+=("$region")
  fi

  if [[ "$AVAILABLE" -ge "$CAPACITY" ]]; then
    return 0
  else
    return 1
  fi
}

# -------------------- Check User-Specified Region --------------------
check_quota "$LOCATION"
primary_status=$?

if [[ $primary_status -eq 2 ]]; then
  echo -e "\n⚠️  Could not retrieve quota info for region: '$LOCATION'."
  exit 1
fi

if [[ $primary_status -eq 1 ]]; then
  primary_entry="${ALL_RESULTS[0]}"
  IFS='|' read -r _ limit used available <<< "$primary_entry"
  echo -e "\n⚠️  Insufficient quota in '$LOCATION' (Available: $available, Required: $CAPACITY). Checking fallback regions..."
fi

# -------------------- Check Fallback Regions --------------------
for region in "${ALL_REGIONS[@]}"; do
  [[ "$region" == "$LOCATION" ]] && continue
  check_quota "$region"
  if [[ $? -eq 0 ]]; then
    FALLBACK_RESULTS+=("$region")
  fi
done

# -------------------- Print Results Table --------------------
echo ""
printf "%-5s | %-16s | %-40s | %-6s | %-6s | %-9s\n" "No." "Region" "Model Name" "Limit" "Used" "Available"
printf -- "---------------------------------------------------------------------------------------------\n"

index=1
for result in "${ALL_RESULTS[@]}"; do
  IFS='|' read -r region limit used available <<< "$result"
  if [[ "$available" -gt 50 ]]; then
    printf "| %-3s | %-16s | %-40s | %-6s | %-6s | %-9s |\n" "$index" "$region" "$MODEL_TYPE" "$limit" "$used" "$available"
    ((index++))
  fi
done
printf -- "-------------------------------------------------------------------------------------------------------------\n"

# -------------------- Ask for Location --------------------
ask_for_location() {
  echo -e "\nPlease enter any other location from the above table where you want to deploy AI Services:"
  read LOCATION < /dev/tty

  if [[ -z "$LOCATION" ]]; then
    echo "❌ ERROR: No location entered. Exiting."
    exit 1
  fi

  echo "🔍 Checking quota in '$LOCATION'..."
  check_quota "$LOCATION"
  user_region_status=$?

  if [[ $user_region_status -eq 0 ]]; then
    if [[ " ${NOT_RECOMMENDED_REGIONS[*]} " == *" $LOCATION "* ]]; then
      echo -e "\n⚠️  \033[1mWarning:\033[0m Region '$LOCATION' has available tokens less than the recommended threshold ($RECOMMENDED_TOKENS)."
      echo "🚨 Your application may not work as expected due to limited quota."
      echo -ne "\n❓ Do you still want to proceed with this region? (y/n): "
      read -r confirmation < /dev/tty

      if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        echo "🔁 Please choose another region."
        ask_for_location
        return
      fi
    fi

    echo -e "✅ Sufficient minimum quota found in '$LOCATION'. Proceeding with deployment."
    azd env set AZURE_AISERVICE_LOCATION "$LOCATION"
    echo "➡️  Set AZURE_AISERVICE_LOCATION to '$LOCATION'."
    exit 0

  elif [[ $user_region_status -eq 2 ]]; then
    echo "⚠️ Could not retrieve quota info for region: '$LOCATION'."
    ask_for_location
  else
    echo "❌ Insufficient quota in '$LOCATION'."
    ask_for_location
  fi
}

# -------------------- Output Result --------------------
if [[ $primary_status -eq 0 ]]; then
  is_recommended=false
  for region in "${RECOMMENDED_REGIONS[@]}"; do
    if [[ "$region" == "$LOCATION" ]]; then
      is_recommended=true
      break
    fi
  done

  if [[ "$is_recommended" == false && ${#RECOMMENDED_REGIONS[@]} -gt 0 ]]; then
    recommended_list=$(IFS=, ; echo "${RECOMMENDED_REGIONS[*]}")
    echo -e "\n⚠️  Selected region '$LOCATION' has sufficient quota but is not among the \033[1mrecommended regions\033[0m (≥ $RECOMMENDED_TOKENS tokens)."
    echo -e "🚨 Your application may not work as expected due to limited quota."
    echo -e "\nℹ️  Recommended regions (≥ $RECOMMENDED_TOKENS tokens available): $recommended_list"
    echo -n "❓ Do you want to choose a recommended region instead? (y/n): "
    read -r user_choice < /dev/tty

    if [[ "$user_choice" =~ ^[Yy]$ ]]; then
      ask_for_location
    else
      echo "✅ Proceeding with '$LOCATION' as selected."
      exit 0
    fi
  else
    echo -e "\n✅ Sufficient quota found in original region '$LOCATION'."
    exit 0
  fi
fi

if [[ ${#FALLBACK_RESULTS[@]} -gt 0 ]]; then
  echo "➡️  Found fallback regions with sufficient quota."

  if [[ ${#RECOMMENDED_REGIONS[@]} -gt 0 ]]; then
    recommended_list=$(IFS=, ; echo "${RECOMMENDED_REGIONS[*]}")
    echo -e "\nℹ️  Recommended regions (≥ $RECOMMENDED_TOKENS tokens available): $recommended_list"
    echo -e "👉 It's advisable to deploy in one of these regions for optimal app performance."
  fi

  ask_for_location
fi
