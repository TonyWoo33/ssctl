# functions/tui.sh
# TUI Module for ssctl v4.0.0-dev

# Helper to hide cursor
tui_init() {
    tput civis
    trap 'tput cnorm; clear' EXIT INT TERM
}

# Helper to cleanup
tui_cleanup() {
    tput cnorm
    clear
}

tui_detect_active_node(){
    local node="${SSCTL_CURRENT_NODE:-}"
    if [ -n "$node" ] && systemctl --user is-active --quiet "sslocal-${node}-*" 2>/dev/null; then
        printf '%s\n' "$node"
        return 0
    fi
    local active_unit
    active_unit="$(systemctl --user list-units --state=active --plain --no-legend 'sslocal-*.service' 2>/dev/null | head -n1 | awk '{print $1}')"
    if [ -n "$active_unit" ]; then
        local tmp="${active_unit#sslocal-}"
        tmp="${tmp%.service}"
        node="${tmp%-*}"
    fi
    printf '%s\n' "$node"
}

# [1] Dashboard Menu
tui_dashboard_menu() {
    clear
    local key
    while true; do
        tput cup 0 0
        echo "=== Live Dashboard (Press 'q' to return) ===$(tput el)"
        echo "--------------------------------------------$(tput el)"
        
        # Fetch Data
        local current_node service_state="Inactive"
        current_node="$(tui_detect_active_node)"
        if [ -n "$current_node" ]; then
            service_state="Active (Running)"
        else
            current_node="Unknown"
        fi
        
        echo "Current Node : $current_node$(tput el)"
        echo "Service State: $service_state$(tput el)"
        echo "Last Update  : $(date +%H:%M:%S)$(tput el)"
        echo "--------------------------------------------$(tput el)"
        tput ed # Clear rest of screen

        # Non-blocking read (1 sec timeout)
        read -t 1 -n 1 -s key
        if [[ "$key" == "q" ]]; then
            break
        fi
    done
}

# [2] Node List Menu
tui_node_list_menu() {
    local nodes=()
    local selected=0
    local key
    
    # Load nodes (hide internal ones starting with _)
    for f in "$HOME/.config/ssctl/nodes/"*.json; do
        [ -e "$f" ] || continue
        local fname=$(basename "$f" .json)
        [[ "$fname" == _* ]] && continue
        nodes+=("$fname")
    done
    
    if [ ${#nodes[@]} -eq 0 ]; then
        echo "No nodes found in ~/.config/ssctl/nodes/"
        read -n 1 -s -r -p "Press any key..."
        return
    fi

    clear
    while true; do
        tput cup 0 0
        echo "=== Node List (Up/Down to Select, Enter to Switch, q to Back) ===$(tput el)"
        
        for i in "${!nodes[@]}"; do
            if [ $i -eq $selected ]; then
                echo "> ${nodes[$i]}$(tput el)"
            else
                echo "  ${nodes[$i]}$(tput el)"
            fi
        done
        tput ed # Clear rest of screen

        # Read input (3 chars for arrows)
        read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key
            if [[ "$key" == "[A" ]]; then # Up
                ((selected--))
                [ $selected -lt 0 ] && selected=0
            elif [[ "$key" == "[B" ]]; then # Down
                ((selected++))
                [ $selected -ge ${#nodes[@]} ] && selected=$((${#nodes[@]} - 1))
            fi
        elif [[ "$key" == "" ]]; then # Enter
            local target="${nodes[$selected]}"
            tput cnorm
            echo ""
            echo "Switching to $target..."
            
            # Dispatch start command
            if type cmd_start &>/dev/null; then
                cmd_start "$target"
            else
                # Fallback if function not directly visible
                ssctl start "$target"
            fi
            
            echo "Done. Press any key..."
            read -n 1 -s
            tput civis
        elif [[ "$key" == "q" ]]; then
            break
        fi
    done
}

# [3] Logs Menu
tui_logs_menu(){
    clear
    local node
    node="$(tui_detect_active_node)"
    if [ -z "$node" ]; then
        echo "No active node found. Start a node first."
        read -n 1 -s -r -p "Press any key to return..."
        clear
        return
    fi

    echo "Loading logs for ${node}... (Press 'q' to exit less, Ctrl+C to scroll)"
    sleep 1
    local unit_pattern="sslocal-${node}-*"
    journalctl --user -u "${unit_pattern}" -n 100 --no-pager | less +F -X
    clear
}

# [4] Subscriptions Menu
tui_sub_menu(){
    clear
    local key config_file="$HOME/.config/ssctl/config.json"
    while true; do
        tput cup 0 0
        echo "=== Subscriptions Menu ===$(tput el)"
        echo "1) Update All Subscriptions$(tput el)"
        echo "2) List Subscription URLs$(tput el)"
        echo "0) Back$(tput el)"
        echo "------------------------$(tput el)"
        echo -n "Select option: "
        tput ed

        read -n 1 -s key
        case "$key" in
            1)
                echo ""
                echo "Updating subscriptions..."
                bash "$0" sub update
                read -n 1 -s -r -p "Press any key to return..."
                clear
                ;;
            2)
                echo ""
                echo "Listing subscription URLs..."
                if [ ! -f "$config_file" ]; then
                    echo "Config not found: $config_file"
                elif ! command -v jq >/dev/null 2>&1; then
                    echo "jq is required to parse subscriptions."
                else
                    local urls
                    urls="$(jq -r '.subscriptions[]? // empty' "$config_file" 2>/dev/null)"
                    if [ -n "$urls" ]; then
                        echo "$urls"
                    else
                        echo "No subscriptions configured."
                    fi
                fi
                echo ""
                read -n 1 -s -r -p "Press any key to return..."
                clear
                ;;
            0|q|Q)
                clear
                break
                ;;
            *)
                echo ""
                echo "Invalid option."
                sleep 0.5
                ;;
        esac
    done
}

# Main Entry Point
cmd_tui() {
    tui_init
    
    local key
    while true; do
        tput cup 0 0
        echo "=== ssctl v4.0.0-dev TUI ===$(tput el)"
        echo "1) Dashboard$(tput el)"
        echo "2) Node List$(tput el)"
        echo "3) Logs$(tput el)"
        echo "4) Subscriptions$(tput el)"
        echo "0) Exit$(tput el)"
        echo "------------------------"
        echo -n "Select option: "
        tput ed

        read -n 1 -s key
        
        case "$key" in
            1) tui_dashboard_menu; clear ;;
            2) tui_node_list_menu; clear ;;
            3) tui_logs_menu; clear; tput civis ;;
            4) tui_sub_menu; tput civis ;;
            0|q) 
                tui_cleanup
                break 
                ;;
        esac
    done
}
