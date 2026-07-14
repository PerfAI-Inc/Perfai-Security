#!/bin/bash

# Default values
WAIT_FOR_COMPLETION=true
FAIL_ON_NEW_LEAKS=false

# Parse the input arguments
TEMP=$(getopt -n "$0" -a -l "hostname:,username:,password:,openApiUrl:,basePath:,orgId:,catalogId:,label:,wait-for-completion:,fail-on-new-leaks:,authenticationUrl1:,authenticationBody1:,authorizationHeaders1:,authenticationUrl2:,authenticationBody2:,authorizationHeaders2:,appUrl:" -- -- "$@")

[ $? -eq 0 ] || exit

eval set -- "$TEMP"

while [ $# -gt 0 ]
do
    case "$1" in
        --hostname) PERFAI_HOSTNAME="$2"; shift;;
        --username) PERFAI_USERNAME="$2"; shift;;
        --password) PERFAI_PASSWORD="$2"; shift;;
        --openApiUrl) OPENAPI_URL="$2"; shift;;
        --basePath) BASE_PATH="$2"; shift;;  
        --orgId) ORG_ID="$2"; shift;;
        --catalogId) CATALOG_ID="$2"; shift;;
        --label) LABEL="$2"; shift;;
        --wait-for-completion) WAIT_FOR_COMPLETION="$2"; shift;;
        --fail-on-new-leaks) FAIL_ON_NEW_LEAKS="$2"; shift;;
        --authenticationUrl1) AUTH_URL_1="$2"; shift;;
        --authenticationBody1) AUTH_BODY_1="$2"; shift;;
        --authorizationHeaders1) AUTH_HEADERS_1="$2"; shift;;
        --authenticationUrl2) AUTH_URL_2="$2"; shift;;
        --authenticationBody2) AUTH_BODY_2="$2"; shift;;
        --authorizationHeaders2) AUTH_HEADERS_2="$2"; shift;;
        --appUrl) APP_URL="$2"; shift;;
        --) shift ;;
    esac
    shift;
done

echo " "

if [ "$PERFAI_HOSTNAME" = "" ];
then
PERFAI_HOSTNAME="https://cloud.perfai.ai"
fi

### Step 1: Authenticate and obtain access token ###
TOKEN_RESPONSE=$(curl -sS --location --request POST "https://api.perfai.ai/api/v1/auth/token" \
--header "x-org-id: $ORG_ID" \
--header "Content-Type: application/json" \
--data-raw "{
    \"username\": \"${PERFAI_USERNAME}\",
    \"password\": \"${PERFAI_PASSWORD}\"
}" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    echo "Error: Failed to connect to Perfai auth API (curl exit $CURL_EXIT): $TOKEN_RESPONSE"
    echo "Check network connectivity and ensure api.perfai.ai is reachable from this host."
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token' 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "Error: Could not retrieve access token. Auth response: $TOKEN_RESPONSE"
    exit 1
fi

# Do not print the token. Under GitHub Actions, register it so the runner scrubs it
# from all subsequent log output; the guard keeps direct/local runs from echoing it.
if [ -n "$GITHUB_ACTIONS" ]; then
    echo "::add-mask::$ACCESS_TOKEN"
fi
echo "Authentication successful."
echo " "

### Step 2: Trigger Vision Agent Scan (disabled) ###
# VISION_TASK_RESPONSE=$(curl -s --location --request POST "https://api.perfai.ai/api/v1/vision-agent-tasks/create-task" \
#   -H "Authorization: Bearer $ACCESS_TOKEN" \
#   -H "x-org-id: $ORG_ID" \
#   -H "Content-Type: application/json" \
#   -d "{
#     \"type\": \"GENERATE_SPEC\",
#     \"org_id\": \"${ORG_ID}\",
#     \"app_id\": \"${CATALOG_ID}\",
#     \"data\": {
#       \"url\": \"${APP_URL}\"
#     }
#   }")
#
# VISION_TASK_ID=$(echo "$VISION_TASK_RESPONSE" | jq -r '._id')
#
# if [ "$WAIT_FOR_COMPLETION" == "true" ]; then
#     VISION_STATUS="PENDING"
#     VISION_START_TIME=$(date +%s)
#     VISION_POLL_COUNT=0
#     VISION_HEARTBEAT_INTERVAL=10
#
#     while [[ "$VISION_STATUS" == "PENDING" || "$VISION_STATUS" == "IN_PROGRESS" ]]; do
#         sleep 30
#         VISION_ELAPSED=$(( ($(date +%s) - VISION_START_TIME) / 60 ))
#         VISION_STATUS_RESPONSE=$(curl -s --location --request GET \
#           "https://api.perfai.ai/api/v1/vision-agent-tasks/get-task/${VISION_TASK_ID}" \
#           -H "Authorization: Bearer $ACCESS_TOKEN" \
#           -H "x-org-id: $ORG_ID")
#         VISION_STATUS=$(echo "$VISION_STATUS_RESPONSE" | jq -r '.status // empty')
#     done
# fi

### Step 3: Trigger sensitive_data_run via chain execution ###
RUN_RESPONSE=$(curl -s --location --request POST "https://api.perfai.ai/chain-execution/execute" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"catalog_id\": \"${CATALOG_ID}\",
    \"chain_config\": {
      \"steps\": [
        {
          \"step_id\": \"sensitive_data_run\",
          \"service\": \"sensitive_data\",
          \"mode\": \"run\",
          \"execution_order\": 1,
          \"is_critical\": true,
          \"enabled\": true,
          \"metadata\": {
            \"categories_to_run\": [
              \"Authorization_Missing\",
              \"Authorization_Invalid\",
              \"Authorization_Expired\",
              \"Authorization_Valid\",
              \"RBAC\",
              \"DB_Read\",
              \"DB_Write\",
              \"BOLA\",
              \"Pagination_Invalid\",
              \"Rate_Limit_Exist\",
              \"Date_Filter_Invalid\",
              \"SSRF\",
              \"Privilege_Escalation\",
              \"CORS_Exist\",
              \"Audit_Data_Tampering\",
              \"Broken_Token_Signature_Verification\",
              \"Broken_Token_Tampered_Payload\",
              \"Monitoring_Endpoint\",
              \"BPLA\",
              \"BTLA\",
              \"BRLA\",
              \"Cross_Environment_Token_Acceptance\",
              \"Cross_Application_Token_Acceptance\",
              \"Broken_Token_Revocation\",
              \"Broken_Logout\",
              \"Search_Data_Leak\",
              \"Data_Access_Authorization_Anomaly\",
              \"BOLA_Cross_Roles\",
              \"BOLA_Cross_Tenant\",
              \"BOLA_Same_Tenant_Ownership\"
            ]
          }
        }
      ]
    }
  }"
)

echo " "
echo "===== Chain Execution Started ====="
echo "$RUN_RESPONSE" | jq '{chain_execution_id, status, total_steps, created_at}' 2>/dev/null || echo "$RUN_RESPONSE"
echo "==================================="
echo " "

CHAIN_EXECUTION_ID=$(echo "$RUN_RESPONSE" | jq -r '.chain_execution_id')

if [ -z "$CHAIN_EXECUTION_ID" ] || [ "$CHAIN_EXECUTION_ID" == "null" ]; then
    echo "Error: Failed to trigger chain execution. No chain_execution_id returned."
    exit 1
fi

echo "Chain Execution ID  : $CHAIN_EXECUTION_ID"
echo " "

### Step 4: Check the wait-for-completion flag ###
if [ "$WAIT_FOR_COMPLETION" == "true" ]; then
    echo "Waiting for sensitive_data_run to complete (this typically takes 5 min for full scan)..."

    STATUS="PENDING"
    LAST_SNAPSHOT=""
    NULL_RETRIES=0
    MAX_NULL_RETRIES=3
    CHAIN_START_TIME=$(date +%s)

    while [[ "$STATUS" == "PENDING" || "$STATUS" == "RUNNING" ]]; do
        sleep 30

        STATUS_RESPONSE=$(curl -s --location --request GET \
          "https://api.perfai.ai/chain-execution/chain/$CHAIN_EXECUTION_ID" \
          --header "Authorization: Bearer $ACCESS_TOKEN")

        if [ -z "$STATUS_RESPONSE" ] || [ "$STATUS_RESPONSE" == "null" ] || ! echo "$STATUS_RESPONSE" | jq -e . >/dev/null 2>&1; then
            NULL_RETRIES=$((NULL_RETRIES + 1))
            FIRST_LINE=$(echo "$STATUS_RESPONSE" | head -1)
            echo "[$(date '+%H:%M:%S')] Warning: non-JSON or empty response from chain execution API (attempt $NULL_RETRIES/$MAX_NULL_RETRIES): $FIRST_LINE"
            if [ "$NULL_RETRIES" -ge "$MAX_NULL_RETRIES" ]; then
                echo "Error: chain execution API returned bad response $MAX_NULL_RETRIES times in a row. Aborting."
                exit 1
            fi
            sleep 30
            continue
        fi

        STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status // empty')

        if [ -z "$STATUS" ] || [ "$STATUS" == "null" ]; then
            NULL_RETRIES=$((NULL_RETRIES + 1))
            echo "[$(date '+%H:%M:%S')] Warning: status field missing in response (attempt $NULL_RETRIES/$MAX_NULL_RETRIES). Raw: $STATUS_RESPONSE"
            if [ "$NULL_RETRIES" -ge "$MAX_NULL_RETRIES" ]; then
                echo "Error: status field missing after $MAX_NULL_RETRIES retries. Last response: $STATUS_RESPONSE"
                exit 1
            fi
            continue
        fi

        NULL_RETRIES=0
        CURRENT_STEP=$(echo "$STATUS_RESPONSE" | jq -r '.current_step_id // "N/A"')
        PROGRESS=$(echo "$STATUS_RESPONSE" | jq -r '.progress_percentage // 0')
        COMPLETED_STEPS=$(echo "$STATUS_RESPONSE" | jq -r '(.completed_steps // []) | join(", ")')
        FAILED_STEPS_LIST=$(echo "$STATUS_RESPONSE" | jq -r '(.failed_steps // []) | join(", ")')
        ELAPSED=$(( ($(date +%s) - CHAIN_START_TIME) / 60 ))

        SNAPSHOT="${STATUS}|${PROGRESS}|${CURRENT_STEP}|${COMPLETED_STEPS}|${FAILED_STEPS_LIST}"

        if [ "$SNAPSHOT" != "$LAST_SNAPSHOT" ]; then
            echo "[$(date '+%H:%M:%S')] Elapsed: ${ELAPSED}m | Status: $STATUS | Progress: ${PROGRESS}% | Current Step: $CURRENT_STEP | Completed: ${COMPLETED_STEPS:-none} | Failed: ${FAILED_STEPS_LIST:-none}"
            LAST_SNAPSHOT="$SNAPSHOT"
        fi
    done

    if [[ "$STATUS" == "COMPLETED" || "$STATUS" == "DONE" || "$STATUS" == "SUCCESS" ]]; then
        ELAPSED_TOTAL=$(( ($(date +%s) - CHAIN_START_TIME) / 60 ))
        echo "sensitive_data_run completed successfully for catalog ID $CATALOG_ID (elapsed: ${ELAPSED_TOTAL}m)."
        echo " "
        echo "===== Security Scan Results ====="
        echo "Chain Execution ID : $CHAIN_EXECUTION_ID"
        echo "Completed Steps    : $(echo "$STATUS_RESPONSE" | jq -r '(.completed_steps // []) | join(", ")')"
        echo "Failed Steps       : $(echo "$STATUS_RESPONSE" | jq -r '(.failed_steps // []) | join(", ")')"
        SCAN_RESULTS=$(echo "$STATUS_RESPONSE" | jq -r '.results // empty')
        if [ -n "$SCAN_RESULTS" ]; then
            echo "Results:"
            echo "$SCAN_RESULTS" | jq . 2>/dev/null || echo "$SCAN_RESULTS"
        fi
        echo "================================="
        echo " "

        ### Fetch Catalog Summary and extract sensitive_app_id ###
        CATALOG_SUMMARY=$(curl -s --location \
          "https://api.perfai.ai/api/v1/api-catalog/apps/summary/${CATALOG_ID}" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "x-org-id: $ORG_ID" \
          -H "accept: application/json")
        SENSITIVE_APP_ID=$(echo "$CATALOG_SUMMARY" | jq -r '.sensitive_app_id // empty')

        if [ -z "$SENSITIVE_APP_ID" ] || [ "$SENSITIVE_APP_ID" == "null" ]; then
            echo "Error: Could not extract sensitive_app_id from catalog summary."
            exit 1
        fi
        echo "Sensitive App ID    : $SENSITIVE_APP_ID"

        ### Fetch Security Issues — poll for up to 5 minutes until issues appear ###
        echo "===== Security Issues ====="
        ISSUES_POLL_INTERVAL=15
        ISSUES_POLL_DEADLINE=$(( $(date +%s) + 300 ))   # 5 minutes
        ISSUE_COUNT=0

        while [ "$(date +%s)" -lt "$ISSUES_POLL_DEADLINE" ]; do
            ISSUES_RESPONSE=$(curl -s --location \
              "https://api.perfai.ai/api/v1/sensitive-data-service/apps/app_issues_security?app_id=${SENSITIVE_APP_ID}&page=1&pageSize=100&sortBy=severity&sortOrder=DESC" \
              -H "Authorization: Bearer $ACCESS_TOKEN" \
              -H "x-org-id: $ORG_ID" \
              -H "accept: application/json")

            if [ -z "$ISSUES_RESPONSE" ] || ! echo "$ISSUES_RESPONSE" | jq -e . >/dev/null 2>&1; then
                echo "[$(date '+%H:%M:%S')] Warning: non-JSON or empty response from security issues API. Retrying in ${ISSUES_POLL_INTERVAL}s..."
                sleep "$ISSUES_POLL_INTERVAL"
                continue
            fi

            ISSUE_COUNT=$(echo "$ISSUES_RESPONSE" | jq '.summary.totalCount // 0' 2>/dev/null || echo "0")

            if [ "$ISSUE_COUNT" -gt 0 ] 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] Issues ready — found $ISSUE_COUNT security issue(s)."
                break
            fi

            REMAINING=$(( ISSUES_POLL_DEADLINE - $(date +%s) ))
            echo "[$(date '+%H:%M:%S')] No issues yet (0 found). Retrying in ${ISSUES_POLL_INTERVAL}s (${REMAINING}s remaining)..."
            sleep "$ISSUES_POLL_INTERVAL"
        done

        if [ "$ISSUE_COUNT" -eq 0 ] 2>/dev/null; then
            echo "[$(date '+%H:%M:%S')] No security issues found after 5 minutes. The scan may still be processing."
        else
            CRITICAL_COUNT=$(echo "$ISSUES_RESPONSE" | jq '.summary.criticalCount // 0')
            HIGH_COUNT=$(echo "$ISSUES_RESPONSE" | jq '.summary.highCount // 0')
            MEDIUM_LOW_COUNT=$(echo "$ISSUES_RESPONSE" | jq '.summary.mediumLowCount // 0')
            TOTAL_SAVINGS=$(echo "$ISSUES_RESPONSE" | jq '.summary.bugBountySavings.totalSavings // 0')

            echo " "
            echo "  Total Issues   : $ISSUE_COUNT"
            echo "  Critical       : $CRITICAL_COUNT"
            echo "  High           : $HIGH_COUNT"
            echo "  Medium / Low   : $MEDIUM_LOW_COUNT"
            echo "  Bounty Savings : \$$TOTAL_SAVINGS"
            echo " "
            echo "$ISSUES_RESPONSE" | jq '{summary}' 2>/dev/null
        fi
        echo "==========================="
    elif [ "$STATUS" == "FAILED" ]; then
        FAILED_STEPS=$(echo "$STATUS_RESPONSE" | jq -r '.failed_steps | join(", ")')
        echo "Error: Chain execution failed. Failed steps: $FAILED_STEPS"
        echo " "
        echo "===== Failure Details ====="
        echo "$STATUS_RESPONSE" | jq '{
          chain_execution_id,
          status,
          failed_steps,
          completed_steps,
          current_step_id,
          step_run_ids,
          completed_at
        }' 2>/dev/null || echo "$STATUS_RESPONSE"
        echo "==========================="

        exit 1
    else
        echo "Chain execution ended with unexpected status: $STATUS"
        echo " "
        echo "===== Unexpected Response ====="
        echo "$STATUS_RESPONSE" | jq '.' 2>/dev/null || echo "$STATUS_RESPONSE"
        echo "==============================="
        exit 1
    fi
else
    echo "sensitive_data_run triggered. Chain Execution ID: $CHAIN_EXECUTION_ID. Exiting without waiting for completion."
    exit 0
fi
