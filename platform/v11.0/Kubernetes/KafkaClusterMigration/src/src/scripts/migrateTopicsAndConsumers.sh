#!/bin/bash

pipe=/tmp/connect_mirror_maker_pipe
mkfifo $pipe

# Start in background
command="./connect-mirror-maker.sh /tmp/mm2.properties"
# To make logs visible remove > /dev/null 2>&1
$command > $pipe 2>&1 &
pid=$!

echo "Started MirrorMaker2 with pid $pid"

# Function to check for the specific message in the named pipe
check_pipe_for_message() {
    while read line; do
        echo "$line"
        if echo "$line" | grep -q "sync idle consumer group offset from source to target took 0 ms"; then
            return 0
        fi
    done < $pipe
    return 1
}

# Main loop
while true; do
    if check_pipe_for_message; then
        echo "Replication is complete. Stopping MirrorMaker."
        kill $pid
        break
    fi
    sleep 10
done

echo "Starting consumer migration."
./migrateConsumers.sh --command-config /tmp/kcs.properties

# Exit the script
exit 0