#!/usr/bin/env fish

set model "gpt-5-nano"
set api "https://api.openai.com/v1/responses"

set allowed_commands ls pwd whoami cat id uname hostname date uptime

set green (printf '\033[32m')
set yellow (printf '\033[33m')
set cyan (printf '\033[36m')
set reset (printf '\033[0m')

set schema '{
  "type": "object",
  "properties": {
    "thinking": { "type": "string" },
    "action": {
      "type": "object", 
      "properties": {
        "type": { "type": "string", "enum": ["respond", "execute"] },
        "content": { "type": "string" }
      },
      "required": ["type", "content"],
      "additionalProperties": false
    }
  },
  "required": ["thinking", "action"],
  "additionalProperties": false
}'

set system_prompt "You are a helpful assistant that can execute shell commands.
You can run these commands: ls, pwd, whoami, cat
When the user asks about files, directories, or system info, use execute to run the appropriate command.
After seeing command output, respond to the user with the information they asked for.
Only use 'execute' when you need command output. Use 'respond' to reply to the user."

set prev_id ""

while true
    read -P "> " -l user_msg
    or break

    if test "$user_msg" = "exit"
        break
    end

    echo ""

    set current_input "$user_msg"
    
    while true
        if test -n "$prev_id"
            set payload (jq -n \
                --arg model "$model" \
                --arg system "$system_prompt" \
                --arg input "$current_input" \
                --arg prev "$prev_id" \
                --argjson schema "$schema" \
                '{
                    model: $model,
                    instructions: $system,
                    input: $input,
                    previous_response_id: $prev,
                    reasoning: {effort: "low"},
                    text: {
                        format: {
                            type: "json_schema",
                            name: "agent_action",
                            strict: true,
                            schema: $schema
                        }
                    }
                }')
        else
            set payload (jq -n \
                --arg model "$model" \
                --arg system "$system_prompt" \
                --arg input "$current_input" \
                --argjson schema "$schema" \
                '{
                    model: $model,
                    instructions: $system,
                    input: $input,
                    reasoning: {effort: "low"},
                    text: {
                        format: {
                            type: "json_schema",
                            name: "agent_action",
                            strict: true,
                            schema: $schema
                        }
                    }
                }')
        end

        set response "$(curl -s $api \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$payload")"

        set output_text "$(echo "$response" | jq -r '.output[] | select(.type == "message") | .content[0].text // empty')"
        set prev_id "$(echo "$response" | jq -r '.id // empty')"

        set thinking "$(echo "$output_text" | jq -r '.thinking // empty')"
        set action_type "$(echo "$output_text" | jq -r '.action.type // empty')"
        set action_content "$(echo "$output_text" | jq -r '.action.content // empty')"

        if test -n "$thinking"
            echo "$yellow💭 $thinking$reset"
            echo ""
        end

        if test "$action_type" = "execute"
            # Check if command is whitelisted
            set cmd (string split ' ' "$action_content")[1]
            if contains "$cmd" $allowed_commands
                echo "$cyan⚡ Running: $action_content$reset"
                set cmd_output "$(eval $action_content 2>&1)"
                echo "$cmd_output"
                echo ""
                # Feed output back to model
                set current_input "Command output for '$action_content':
$cmd_output"
            else
                echo "$yellow⚠️  Command '$cmd' not allowed$reset"
                set current_input "Error: Command '$cmd' is not in the whitelist. Allowed: ls, pwd, whoami, cat"
            end
        else if test "$action_type" = "respond"
            # Stream the final response using previous_response_id for context
            set stream_payload (jq -n \
                --arg model "$model" \
                --arg input "Please respond to the user now." \
                --arg prev "$prev_id" \
                '{model: $model, input: $input, previous_response_id: $prev, stream: true}')
            
            set tmpfile (mktemp)
            curl -sN $api \
                -H "Authorization: Bearer $OPENAI_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$stream_payload" | stdbuf -oL tee $tmpfile | stdbuf -oL sed -un 's/^data: //p' | stdbuf -oL jq --unbuffered -rj 'select(.type == "response.output_text.delta") | .delta // empty'
            
            set prev_id (grep '^data:.*response.completed' $tmpfile | sed 's/^data: //' | jq -r '.response.id // empty' 2>/dev/null)
            rm $tmpfile
            break
        else
            echo "Error parsing response"
            break
        end
    end

    echo ""
end
