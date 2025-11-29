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
            '{model: $model, input: $input, previous_response_id: $prev, stream: true, reasoning: {summary: "auto"}}')
    else
        set payload (jq -n \
            --arg model "$model" \
            --arg input "$user_msg" \
            '{model: $model, input: $input, stream: true, reasoning: {summary: "auto"}}')
    end

    echo ""

    set tmpfile (mktemp)
    set gray (printf '\033[90m')
    set reset (printf '\033[0m')
    
    curl -sN $api \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" | stdbuf -oL tee $tmpfile | stdbuf -oL sed -un 's/^data: //p' | stdbuf -oL jq --unbuffered -rj --arg gray "$gray" --arg reset "$reset" '
            if .type == "response.reasoning_summary_part.added" then $gray
            elif .type == "response.reasoning_summary_text.delta" then .delta // empty
            elif .type == "response.reasoning_summary_text.done" then "\($reset)\n\n"
            elif .type == "response.output_text.delta" then .delta // empty
            else empty end'
    
    set prev_id (grep '^data:.*response.completed' $tmpfile | sed 's/^data: //' | jq -r '.response.id // empty' 2>/dev/null)

    rm $tmpfile

    echo ""
end
