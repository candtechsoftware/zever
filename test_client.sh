#!/bin/bash

# Default values
CLIENTS=1
REQUEST_INTERVAL=1
SERVER_HOST="127.0.0.1"
SERVER_PORT="8080"
TIMEOUT=5

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -clients=*)
            CLIENTS="${1#*=}"
            shift
            ;;
        -interval=*)
            REQUEST_INTERVAL="${1#*=}"
            shift
            ;;
        *)
            echo "Usage: $0 [-clients=NUMBER] [-interval=SECONDS]"
            echo "  -clients=NUMBER    Number of parallel clients (default: 1)"
            echo "  -interval=SECONDS  Interval between requests (default: 1)"
            exit 1
            ;;
    esac
done

# Function to run a single client
run_client() {
    local client_id=$1
    local counter=1
    
    while true; do
        echo "[Client $client_id] ==================== Request #$counter - $(date) ===================="
        # Send HTTP GET request using curl with timeout and better error handling
        response=$(curl -s -m $TIMEOUT \
                       --connect-timeout $TIMEOUT \
                       -w "\n---\nHTTP_CODE:%{http_code}\nTIME:%{time_total}s\nSIZE:%{size_download} bytes" \
                       -H "User-Agent: ZeverTestScript-Client$client_id/1.0" \
                       -H "Accept: application/json" \
                       -H "Connection: close" \
                       "http://$SERVER_HOST:$SERVER_PORT/test?param=value&client=$client_id" 2>&1)
        
        curl_exit_code=$?
        
        if [ $curl_exit_code -eq 0 ]; then
            echo "[Client $client_id] ✓ SUCCESS"
            
            # Only show detailed output if single client mode
            if [ $CLIENTS -eq 1 ]; then
                # Extract just the JSON body (everything before the ---HTTP_CODE line)
                json_body=$(echo "$response" | sed '/^---$/,$d')
                
                # Try to pretty print JSON if jq is available
                if command -v jq &> /dev/null; then
                    echo "📝 Pretty JSON:"
                    echo "$json_body" | jq . 2>/dev/null || echo "$json_body"
                else
                    echo "$json_body"
                fi
            fi
            
            # Always show the stats
            echo "$response" | grep -A3 "^---$" | sed "s/^/[Client $client_id] /"
        else
            case $curl_exit_code in
                7)  echo "[Client $client_id] ✗ FAILED - Connection refused (server not running?)" ;;
                28) echo "[Client $client_id] ✗ FAILED - Timeout after ${TIMEOUT}s (server hanging?)" ;;
                52) echo "[Client $client_id] ✗ FAILED - Server returned nothing (empty response)" ;;
                56) echo "[Client $client_id] ✗ FAILED - Network unreachable" ;;
                *)  echo "[Client $client_id] ✗ FAILED - curl error code: $curl_exit_code" ;;
            esac
        fi
        
        ((counter++))
        sleep $REQUEST_INTERVAL
    done
}

# Main execution
echo "Starting $CLIENTS client(s) testing server at $SERVER_HOST:$SERVER_PORT"
echo "Request interval: ${REQUEST_INTERVAL}s, Timeout: ${TIMEOUT}s"
echo ""

if [ $CLIENTS -eq 1 ]; then
    # Single client mode - run directly
    run_client 1
else
    # Multiple clients - run in background
    echo "Launching $CLIENTS parallel clients..."
    echo "Press Ctrl+C to stop all clients"
    echo ""
    
    # Array to store PIDs
    pids=()
    
    # Launch clients in background
    for ((i=1; i<=CLIENTS; i++)); do
        run_client $i &
        pids+=($!)
    done
    
    # Trap to kill all background processes on exit
    trap "echo 'Stopping all clients...'; kill ${pids[@]} 2>/dev/null; exit" INT TERM
    
    # Wait for all background processes
    wait
fi
