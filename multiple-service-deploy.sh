#!/bin/bash

# Default values
WAIT_FOR_COMPLETION=true
FAIL_ON_NEW_LEAKS=false

# Parse the input arguments
TEMP=$(getopt -n "$0" -a -l "hostname:,username:,password:,openApiUrl:,basePath:,orgId:,appId:,label:,wait-for-completion:,fail-on-new-leaks:,authenticationUrl1:,authenticationBody1:,authorizationHeaders1:,authenticationUrl2:,authenticationBody2:,authorizationHeaders2:,appUrl:" -- -- "$@")

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
        --appId) APP_ID="$2"; shift;;
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

### Step 1: Print Access Token ###
TOKEN_RESPONSE=$(curl -s --location --request POST "https://api.perfai.ai/api/v1/auth/token" \
--header "x-org-id: $ORG_ID" \
--header "Content-Type: application/json" \
--data-raw "{
    \"username\": \"${PERFAI_USERNAME}\",
    \"password\": \"${PERFAI_PASSWORD}\"
}")

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.id_token')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Could not retrieve access token"
    exit 1
fi

echo "Access Token is: $ACCESS_TOKEN"
echo " "

### Step 2: Trigger Vision Agent Scan ###
if [ -n "$APP_URL" ]; then
    echo "Triggering Vision Agent Scan for URL: $APP_URL"
    echo " "

    VISION_TASK_RESPONSE=$(curl -s --location --request POST "https://api.perfai.ai/api/v1/vision-agent-tasks/create-task" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "x-org-id: $ORG_ID" \
      -H "Content-Type: application/json" \
      -d "{
        \"type\": \"GENERATE_SPEC\",
        \"org_id\": \"${ORG_ID}\",
        \"app_id\": \"${APP_ID}\",
        \"data\": {
          \"url\": \"${APP_URL}\"
        }
      }")

    echo "Vision Task Response: $VISION_TASK_RESPONSE"
    echo " "

    VISION_TASK_ID=$(echo "$VISION_TASK_RESPONSE" | jq -r '._id')

    if [ -z "$VISION_TASK_ID" ] || [ "$VISION_TASK_ID" == "null" ]; then
        echo "Error: Failed to create vision agent task. No task ID returned."
        exit 1
    fi

    echo "Vision Agent Task ID: $VISION_TASK_ID"

    if [ "$WAIT_FOR_COMPLETION" == "true" ]; then
        echo "Waiting for vision agent scan to complete..."

        VISION_STATUS="PENDING"
        VISION_LAST_SNAPSHOT=""

        while [[ "$VISION_STATUS" == "PENDING" || "$VISION_STATUS" == "IN_PROGRESS" ]]; do
            sleep 15

            VISION_STATUS_RESPONSE=$(curl -s --location --request GET \
              "https://api.perfai.ai/api/v1/vision-agent-tasks/get-task/${VISION_TASK_ID}" \
              -H "Authorization: Bearer $ACCESS_TOKEN" \
              -H "x-org-id: $ORG_ID")

            if [ -z "$VISION_STATUS_RESPONSE" ] || [ "$VISION_STATUS_RESPONSE" == "null" ]; then
                echo "Error: Received empty response from vision agent task API."
                exit 1
            fi

            VISION_STATUS=$(echo "$VISION_STATUS_RESPONSE" | jq -r '.status')
            VISION_IS_ERROR=$(echo "$VISION_STATUS_RESPONSE" | jq -r '.isError')
            VISION_MESSAGE=$(echo "$VISION_STATUS_RESPONSE" | jq -r '.message // "N/A"')
            VISION_SNAPSHOT="${VISION_STATUS}|${VISION_IS_ERROR}|${VISION_MESSAGE}"

            if [ "$VISION_SNAPSHOT" != "$VISION_LAST_SNAPSHOT" ]; then
                echo "[$(date '+%H:%M:%S')] Vision Agent Status: $VISION_STATUS | Error: $VISION_IS_ERROR | Message: $VISION_MESSAGE"
                VISION_LAST_SNAPSHOT="$VISION_SNAPSHOT"
            fi
        done

        if [ "$VISION_STATUS" == "COMPLETED" ]; then
            echo "Vision agent scan completed successfully."
        elif [ "$VISION_STATUS" == "FAILED" ] || [ "$VISION_STATUS" == "ABORTED" ]; then
            echo "Error: Vision agent scan ended with status: $VISION_STATUS. Message: $VISION_MESSAGE"
            exit 1
        else
            echo "Vision agent scan ended with unexpected status: $VISION_STATUS"
            exit 1
        fi
    else
        echo "Vision agent scan triggered. Task ID: $VISION_TASK_ID. Continuing without waiting."
    fi

    echo " "
fi

### Step 3: Trigger sensitive_data_run via chain execution ###
RUN_RESPONSE=$(curl -s --location --request POST "https://api.perfai.ai/chain-execution/execute" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"catalog_id\": \"${APP_ID}\",
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
echo "Run Response: $RUN_RESPONSE"
echo " "

CHAIN_EXECUTION_ID=$(echo "$RUN_RESPONSE" | jq -r '.chain_execution_id')
TERMINAL_SESSION_ID=$(echo "$RUN_RESPONSE" | jq -r '.terminal_session_id // "N/A"')

if [ -z "$CHAIN_EXECUTION_ID" ] || [ "$CHAIN_EXECUTION_ID" == "null" ]; then
    echo "Error: Failed to trigger chain execution. No chain_execution_id returned."
    exit 1
fi

echo "Chain Execution ID  : $CHAIN_EXECUTION_ID"
echo "Terminal Session ID : $TERMINAL_SESSION_ID"

### Step 4: Check the wait-for-completion flag ###
if [ "$WAIT_FOR_COMPLETION" == "true" ]; then
    echo "Waiting for sensitive_data_run to complete..."

    STATUS="PENDING"
    LAST_SNAPSHOT=""
    NULL_RETRIES=0
    MAX_NULL_RETRIES=3

    while [[ "$STATUS" == "PENDING" || "$STATUS" == "RUNNING" ]]; do
        sleep 15

        STATUS_RESPONSE=$(curl -s --location --request GET \
          "https://api.perfai.ai/chain-execution/chain/$CHAIN_EXECUTION_ID" \
          --header "Authorization: Bearer $ACCESS_TOKEN")

        if [ -z "$STATUS_RESPONSE" ] || [ "$STATUS_RESPONSE" == "null" ]; then
            echo "Error: Received empty response from the API."
            exit 1
        fi

        STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status // empty')

        if [ -z "$STATUS" ] || [ "$STATUS" == "null" ]; then
            NULL_RETRIES=$((NULL_RETRIES + 1))
            echo "[$(date '+%H:%M:%S')] Warning: status field missing in response (attempt $NULL_RETRIES/$MAX_NULL_RETRIES). Raw response: $STATUS_RESPONSE"
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
        POLL_TERMINAL_ID=$(echo "$STATUS_RESPONSE" | jq -r '.terminal_session_id // "N/A"')

        SNAPSHOT="${STATUS}|${PROGRESS}|${CURRENT_STEP}|${COMPLETED_STEPS}|${FAILED_STEPS_LIST}|${POLL_TERMINAL_ID}"

        if [ "$SNAPSHOT" != "$LAST_SNAPSHOT" ]; then
            echo "[$(date '+%H:%M:%S')] Status: $STATUS | Progress: ${PROGRESS}% | Current Step: $CURRENT_STEP | Completed: ${COMPLETED_STEPS:-none} | Failed: ${FAILED_STEPS_LIST:-none} | Terminal Session: $POLL_TERMINAL_ID"
            LAST_SNAPSHOT="$SNAPSHOT"
        fi
    done

    if [[ "$STATUS" == "COMPLETED" || "$STATUS" == "DONE" || "$STATUS" == "SUCCESS" ]]; then
        echo "sensitive_data_run completed successfully for catalog ID $APP_ID."
    elif [ "$STATUS" == "FAILED" ]; then
        FAILED_STEPS=$(echo "$STATUS_RESPONSE" | jq -r '.failed_steps | join(", ")')
        echo "Error: Chain execution failed. Failed steps: $FAILED_STEPS"
        exit 1
    else
        echo "Chain execution ended with unexpected status: $STATUS"
        echo "Raw response: $STATUS_RESPONSE"
        exit 1
    fi
else
    echo "sensitive_data_run triggered. Chain Execution ID: $CHAIN_EXECUTION_ID. Exiting without waiting for completion."
    exit 0
fi
