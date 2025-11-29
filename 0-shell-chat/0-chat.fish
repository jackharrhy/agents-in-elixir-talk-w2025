#!/usr/bin/env fish

set model "gpt-5-nano"
set api "https://api.openai.com/v1/responses"

set prev_id ""

while true
    read -P "> " -l user_msg
    or break

    if test "$user_msg" = "exit"
        break
    end

    if test -n "$prev_id"
        set payload (jq -n \
            --arg model "$model" \
            --arg input "$user_msg" \
            --arg prev "$prev_id" \
            '{model: $model, input: $input, previous_response_id: $prev}')
    else
        set payload (jq -n \
            --arg model "$model" \
            --arg input "$user_msg" \
            '{model: $model, input: $input}')
    end

    set response (curl -s $api \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    set reply (echo "$response" | jq -r '.output[] | select(.type == "message") | .content[0].text')
    set prev_id (echo "$response" | jq -r '.id')

    echo ""
    echo "$reply"
    echo ""
end
