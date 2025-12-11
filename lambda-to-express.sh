#!/usr/bin/env bash

# Requirements: awscli, jq, curl
# Set OPENAI_API_KEY in env.

set -e

OUTPUT_DIR="migration_output"
mkdir -p "$OUTPUT_DIR/lambdas" "$OUTPUT_DIR/routes" "$OUTPUT_DIR/converted"

###############################
# 1. List all Lambda functions
###############################

echo "Listing Lambda functions..."
aws lambda list-functions --output json > "$OUTPUT_DIR/lambda_list.json"

jq -r '.Functions[].FunctionName' "$OUTPUT_DIR/lambda_list.json" > "$OUTPUT_DIR/lambda_names.txt"

####################################
# 2. Download all Lambda code (zip)
####################################

echo "Downloading Lambda code..."
while read -r FN; do
  echo "Fetching $FN"
  aws lambda get-function --function-name "$FN" --output json > "$OUTPUT_DIR/lambdas/${FN}.json"
  CODE_URL=$(jq -r '.Code.Location' "$OUTPUT_DIR/lambdas/${FN}.json")
  curl -sL "$CODE_URL" -o "$OUTPUT_DIR/lambdas/${FN}.zip"
  mkdir -p "$OUTPUT_DIR/lambdas/${FN}"
  unzip -q "$OUTPUT_DIR/lambdas/${FN}.zip" -d "$OUTPUT_DIR/lambdas/${FN}"

done < "$OUTPUT_DIR/lambda_names.txt"

####################################################
# 3. Extract handler code and send to OpenAI for rewrite
####################################################

convert_code() {
  FN="$1"
  HANDLER_PATH=$(jq -r '.Configuration.Handler' "$OUTPUT_DIR/lambdas/${FN}.json")
  HANDLER_FILE="${HANDLER_PATH%%.*}.js"

  if [ ! -f "$OUTPUT_DIR/lambdas/${FN}/$HANDLER_FILE" ]; then
    echo "Handler file not found for $FN, skipping" >&2
    return
  fi

  ORIGINAL_CODE=$(cat "$OUTPUT_DIR/lambdas/${FN}/$HANDLER_FILE")

  PROMPT="Convert this AWS Lambda handler code into a pure Express route handler. Replace event/context usages with req.body, req.params, req.query as appropriate. Only output valid JS code.\n\n$ORIGINAL_CODE"

  RESPONSE=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "{\"model\":\"gpt-5.1\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}]}" )

  echo "$RESPONSE" | jq -r '.choices[0].message.content' > "$OUTPUT_DIR/converted/${FN}.js"
}

echo "Converting Lambda handlers..."
while read -r FN; do
  echo "Converting $FN"
  convert_code "$FN"
done < "$OUTPUT_DIR/lambda_names.txt"

#########################################################
# 4. Extract API Gateway routes and generate server.js
#########################################################

echo "Extracting API Gateway routes..."
aws apigateway get-rest-apis > "$OUTPUT_DIR/apis.json"
API_ID=$(jq -r '.items[0].id' "$OUTPUT_DIR/apis.json")
aws apigateway get-resources --rest-api-id "$API_ID" > "$OUTPUT_DIR/resources.json"

jq -r '.items[] | select(.resourceMethods != null) | {path, methods: (.resourceMethods|keys)}' "$OUTPUT_DIR/resources.json" > "$OUTPUT_DIR/routes/routes.json"

#########################################################
# 5. Build minimal Node.js server
#########################################################

SERVER_FILE="$OUTPUT_DIR/server.js"
cat > "$SERVER_FILE" << 'EOF'
import express from 'express';
import bodyParser from 'body-parser';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
app.use(bodyParser.json());

// Auto-load converted routes
import fs from 'fs';
const routesDir = path.join(__dirname, 'converted');

fs.readdirSync(routesDir).forEach(file => {
  if (file.endsWith('.js')) {
    const routeHandler = (await import(path.join(routesDir, file))).default;
    const routePath = '/' + file.replace('.js','');
    app.all(routePath, routeHandler);
  }
});

app.listen(3000, () => {
  console.log('Server running on port 3000');
});
EOF

echo "Done. Output in $OUTPUT_DIR"
