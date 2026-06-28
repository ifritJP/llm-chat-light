import os
import sys
import traceback
import json
import select
import httpx

# Log file configuration
LOG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "tmp")
LOG_FILE = os.path.join(LOG_DIR, "error.log")

def write_error_log(message: str, exc: Exception = None):
    """Write detailed error information to a log file"""
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write("--- Error Entry ---\n")
            f.write(f"Message: {message}\n")
            if exc:
                f.write(f"Exception: {str(exc)}\n")
                f.write("Traceback:\n")
                traceback.print_exc(file=f)
            f.write("\n")
    except Exception as log_err:
        # If writing to the log file fails, output a brief error message to stderr
        sys.stderr.write(f"Failed to write log: {log_err}\n")

def save_session(session_file: str, messages: list):
    """Overwrite and save the message history to the session file as JSON"""
    try:
        session_dir = os.path.dirname(session_file)
        if session_dir:
            os.makedirs(session_dir, exist_ok=True)
        with open(session_file, "w", encoding="utf-8") as f:
            json.dump(messages, f, ensure_ascii=False, indent=2)
    except Exception as e:
        write_error_log(f"Failed to save session file to {session_file}", e)

def read_multiline_input() -> str:
    """Read multi-line input from stdin all at once"""
    lines = []
    # Read the first line in a blocking manner (waiting for input)
    first_line = sys.stdin.readline()
    if not first_line:
        return ""
    lines.append(first_line)
    
    # Non-blockingly check if there's remaining data on stdin, then read it
    while True:
        r, _, _ = select.select([sys.stdin], [], [], 0.05)
        if r:
            line = sys.stdin.readline()
            if not line:
                break
            lines.append(line)
        else:
            break
            
    return "".join(lines)

def get_available_models(client, api_key):
    try:
        headers = {"Authorization": f"Bearer {api_key}"}
        response = client.get("models", headers=headers)
        if response.status_code == 200:
            res_json = response.json()
            model_ids = []
            
            # 1. LM Studio unique format (models array)
            if "models" in res_json:
                models_data = res_json.get("models", [])
                for item in models_data:
                    if isinstance(item, dict):
                        key = item.get("key")
                        if key and key not in model_ids:
                            model_ids.append(key)
                        variants = item.get("variants", [])
                        for var in variants:
                            if var and var not in model_ids:
                                model_ids.append(var)
                                
            # 2. OpenAI compatible format (data array)
            if "data" in res_json:
                data_list = res_json.get("data", [])
                for item in data_list:
                    if isinstance(item, dict):
                        m_id = item.get("id")
                        if m_id and m_id not in model_ids:
                            model_ids.append(m_id)
            
            return model_ids
        else:
            write_error_log(f"Failed to fetch models. Status: {response.status_code}, Response: {response.text}")
    except Exception as e:
        write_error_log("Failed to fetch models list", e)
    return []

def main():
    api_base = os.getenv("LLM_API_BASE", "http://localhost:1234/api/v1").rstrip("/")
    if api_base.endswith("/v1") and not api_base.endswith("/api/v1"):
        api_base = api_base[:-3] + "/api/v1"
    
    api_key = os.getenv("LLM_API_KEY", "lm-studio")
    model = os.getenv("LLM_MODEL", "default")
    reasoning = os.getenv("LLM_REASONING", "none").lower()
    if reasoning not in ["none", "off", "low", "medium", "high", "on"]:
        reasoning = "none"

    # Handle the --list-models argument
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--list-models":
        client = httpx.Client(base_url=api_base, timeout=10.0)
        models = get_available_models(client, api_key)
        print(json.dumps(models))
        sys.exit(0)

    # Set stdout buffering to line-buffered
    sys.stdout.reconfigure(line_buffering=True)

    session_file = os.getenv("LLM_SESSION_FILE")
    if not session_file:
        session_file = os.path.join(LOG_DIR, "session.json")
    messages = []
    system_prompt = os.getenv("LLM_SYSTEM_PROMPT", "").strip()

    # Load existing session history if available
    if os.path.exists(session_file):
        try:
            with open(session_file, "r", encoding="utf-8") as f:
                messages = json.load(f)
            display_path = os.path.relpath(session_file)
            sys.stdout.write(f"[Loaded session history from {display_path} ({len(messages)} messages)]\n\n")
            
            # Inject/update the system prompt (typically done by Emacs, but synchronized here for safety)
            if system_prompt:
                if not messages:
                    messages.append({"role": "system", "content": system_prompt})
                elif messages[0].get("role") != "system":
                    messages.insert(0, {"role": "system", "content": system_prompt})
                else:
                    messages[0]["content"] = system_prompt
            
            for msg in messages:
                role = msg.get("role")
                content = msg.get("content", "")
                if role == "user":
                    sys.stdout.write(f"llm-chat> {content}\n")
                elif role == "assistant":
                    sys.stdout.write(f"Assistant> {content}\n\n")
            sys.stdout.flush()
        except Exception as load_err:
            write_error_log("Failed to load session file", load_err)
    else:
        # Set system prompt for a new session
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})

    client = httpx.Client(base_url=api_base, timeout=60.0)

    while True:
        try:
            # Print prompt
            sys.stdout.write("llm-chat> ")
            sys.stdout.flush()

            # Read from stdin
            line = read_multiline_input()
            if not line:
                # Exit if EOF is reached
                break

            prompt = line.strip()
            if not prompt:
                continue

            # Handle special commands
            if prompt == "/models":
                models = get_available_models(client, api_key)
                if models:
                    sys.stdout.write("\nAvailable Models:\n")
                    for idx, m_id in enumerate(models, 1):
                        status = " (active)" if m_id == model else ""
                        sys.stdout.write(f"  {idx}. {m_id}{status}\n")
                    sys.stdout.write("\n")
                else:
                    sys.stdout.write("\nNo available models found or failed to fetch models list.\n\n")
                sys.stdout.flush()
                continue
            
            elif prompt == "/reasoning":
                sys.stdout.write(f"\nReasoning mode is currently: \033[36m{reasoning}\033[0m\n\n")
                sys.stdout.flush()
                continue
                
            elif prompt.startswith("/reasoning "):
                val = prompt[11:].strip().lower()
                if val in ["none", "off", "low", "medium", "high", "on"]:
                    reasoning = val
                    sys.stdout.write(f"\nReasoning mode changed to: \033[36m{reasoning}\033[0m\n\n")
                else:
                    sys.stdout.write("\nUsage: /reasoning <none|off|low|medium|high|on>\n\n")
                sys.stdout.flush()
                continue
            
            elif prompt.startswith("/model "):
                target_model = prompt[7:].strip()
                if not target_model:
                    sys.stdout.write("\nUsage: /model <model_name>\n\n")
                    sys.stdout.flush()
                    continue
                
                models = get_available_models(client, api_key)
                matched_model = None
                if models:
                    # Exact match lookup
                    for m_id in models:
                        if m_id == target_model:
                            matched_model = m_id
                            break
                    # Partial match lookup
                    if not matched_model:
                        for m_id in models:
                            if target_model in m_id:
                                matched_model = m_id
                                break
                
                if matched_model:
                    model = matched_model
                    sys.stdout.write(f"\nModel changed to: \033[36m{model}\033[0m\n\n")
                else:
                    sys.stdout.write(f"\n\033[31mError: Model '{target_model}' not found in LM Studio.\033[0m\n")
                    if models:
                        sys.stdout.write("Available models:\n")
                        for m_id in models:
                            sys.stdout.write(f"  - {m_id}\n")
                    sys.stdout.write("\n")
                sys.stdout.flush()
                continue

            # Append user message to history and save
            messages.append({"role": "user", "content": prompt})
            save_session(session_file, messages)

            # Format message history as plain text lines for "input"
            formatted_history = []
            sys_prompt = ""
            for msg in messages:
                role = msg.get("role")
                content = msg.get("content", "")
                if role == "system":
                    sys_prompt = content
                elif role == "user":
                    formatted_history.append(f"User: {content}")
                elif role == "assistant":
                    formatted_history.append(f"Assistant: {content}")
            
            payload = {
                "model": model,
                "input": "\n".join(formatted_history),
                "stream": True,
                "store": False
            }
            if sys_prompt:
                payload["system_prompt"] = sys_prompt
            if reasoning != "none":
                payload["reasoning"] = reasoning

            # Send streaming request
            headers = {"Authorization": f"Bearer {api_key}"}
            with client.stream("POST", "/chat", json=payload, headers=headers) as response:
                if response.status_code != 200:
                    detail_msg = ""
                    try:
                        error_body = response.read().decode("utf-8", errors="ignore")
                        try:
                            error_json = json.loads(error_body)
                            detail_msg = error_json.get("error", {}).get("message", "")
                        except Exception:
                            pass
                    except Exception as read_err:
                        error_body = f"(Could not read response body: {read_err})"
                    
                    err_msg = f"API status code {response.status_code}. Response: {error_body}"
                    write_error_log(err_msg)
                    
                    if detail_msg:
                        sys.stdout.write(f"\n[Error: {detail_msg} (Status: {response.status_code})]\n")
                    else:
                        sys.stdout.write(f"\n[Error: API status code {response.status_code}. Check tmp/error.log for details.]\n")
                    sys.stdout.flush()
                    if messages:
                        messages.pop()
                    continue

                # Print assistant prompt
                sys.stdout.write("\nAssistant> ")
                sys.stdout.flush()

                current_event = None
                assistant_response = ""
                last_response_id = None
                for chunk in response.iter_lines():
                    if not chunk:
                        continue
                    if chunk.startswith("event: "):
                        current_event = chunk[7:].strip()
                    elif chunk.startswith("data: "):
                        data_str = chunk[6:].strip()
                        try:
                            data = json.loads(data_str)
                            if current_event == "message.delta":
                                content = data.get("content", "")
                                if content:
                                    sys.stdout.write(content)
                                    sys.stdout.flush()
                                    assistant_response += content
                            elif current_event == "chat.end":
                                result = data.get("result", {})
                                stats = result.get("stats", {})
                                if stats:
                                    p_tokens = stats.get("input_tokens", 0)
                                    c_tokens = stats.get("total_output_tokens", 0)
                                    t_tokens = p_tokens + c_tokens
                                    sys.stdout.write(f"\n[TokenUsage: {p_tokens}, {c_tokens}, {t_tokens}]\n")
                                    sys.stdout.flush()
                                
                                resp_id = result.get("response_id")
                                if resp_id:
                                    last_response_id = resp_id
                                break
                        except json.JSONDecodeError as json_err:
                            write_error_log("Failed to parse SSE JSON chunk", json_err)
                        except Exception as e:
                            write_error_log("Error parsing chunk or extracting content", e)

            # Append assistant response to history
            if assistant_response:
                assistant_msg = {"role": "assistant", "content": assistant_response}
                if last_response_id:
                    assistant_msg["response_id"] = last_response_id
                messages.append(assistant_msg)
                save_session(session_file, messages)

            # Write newlines
            sys.stdout.write("\n\n")
            sys.stdout.flush()

        except KeyboardInterrupt:
            sys.stdout.write("\n[Interrupted]\n")
            sys.stdout.flush()
        except httpx.RequestError as req_err:
            write_error_log("HTTP connection error", req_err)
            sys.stdout.write(f"\n[Connection Error: {str(req_err)}. Check tmp/error.log for details.]\n")
            sys.stdout.flush()
        except Exception as e:
            write_error_log("Unexpected error in main loop", e)
            sys.stdout.write(f"\n[Unexpected Error: {str(e)}. Check tmp/error.log for details.]\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
