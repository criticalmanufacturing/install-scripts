#!/bin/bash

# Convert system name to lowercase
LOWERED_OLD_SYSTEM_NAME="${OLD_SYSTEM_NAME,,}"
LOWERED_NEW_SYSTEM_NAME="${NEW_SYSTEM_NAME,,}"

# Mapping of old consumer group names to new consumer group names
declare -A CONSUMER_GROUPS
CONSUMER_GROUPS=(
  ["CDMBuilder"]="${LOWERED_NEW_SYSTEM_NAME}_cdm_builder"
  ["EventRuleResults.EPF"]="${LOWERED_NEW_SYSTEM_NAME}_event_rule_results_epf"
  ["MESEventToTable.EPF"]="${LOWERED_NEW_SYSTEM_NAME}_mes_event_to_table_epf"
  ["MESEvents.EPF"]="${LOWERED_NEW_SYSTEM_NAME}_mes_events_epf"
  ["MESEventToCDM.EPF"]="${LOWERED_NEW_SYSTEM_NAME}_mes_event_to_cdm_epf"
  ["CDMProcessor.EPF"]="${LOWERED_NEW_SYSTEM_NAME}_cdm_processor_epf"
  ["${OLD_SYSTEM_NAME}__T_SubstrateDevice_consumer"]="${LOWERED_NEW_SYSTEM_NAME}__t_substrate_device_consumer"
  ["${LOWERED_OLD_SYSTEM_NAME}_iotactionexecutor_group"]="${LOWERED_NEW_SYSTEM_NAME}_workflowexecutor_group"
)

# Get the list of all consumer groups
CONSUMER_GROUPS_LIST=$(kafka-consumer-groups.sh --bootstrap-server $SOURCE_BOOTSTRAP_SERVERS --list)

# Process each consumer group
for CONSUMER_GROUP in $CONSUMER_GROUPS_LIST; do
    CONSUMER_GROUP_LOWER=$(echo "$CONSUMER_GROUP" | tr '[:upper:]' '[:lower:]')

    # Check if the consumer group is in the list
    if [[ ${CONSUMER_GROUPS[$CONSUMER_GROUP]} ]]; then
        NEW_CONSUMER_GROUP=${CONSUMER_GROUPS[$CONSUMER_GROUP]}
    else
        # If consumer group starts with old system name followed by underscore
        if [[ $CONSUMER_GROUP == ${OLD_SYSTEM_NAME}_* ]]; then
            NEW_CONSUMER_GROUP="${LOWERED_NEW_SYSTEM_NAME}_${CONSUMER_GROUP#${OLD_SYSTEM_NAME}_}"
        # If consumer group starts with old system name in lower case followed by underscore
        elif [[ $CONSUMER_GROUP_LOWER == ${LOWERED_OLD_SYSTEM_NAME}_* ]]; then
            NEW_CONSUMER_GROUP="${LOWERED_NEW_SYSTEM_NAME}_${CONSUMER_GROUP#${LOWERED_OLD_SYSTEM_NAME}_}"
        # If consumer group starts with ch_
        elif [[ $CONSUMER_GROUP == ch_* ]]; then
            NEW_CONSUMER_GROUP="${LOWERED_NEW_SYSTEM_NAME}_${CONSUMER_GROUP}"
        else
            continue
        fi
    fi

    # Get the list of topics and offsets for the current consumer group
    TOPIC_PARTITION_OFFSETS=$(kafka-consumer-groups.sh --bootstrap-server $TARGET_BOOTSTRAP_SERVERS --command-config /tmp/kcs.properties --describe --group $CONSUMER_GROUP | awk 'NR>1 {print $2,$3,$4}')
    
    FIRST_LINE=true
    # Create the new consumer group with the same topics and offsets
    while IFS= read -r TOPIC_PARTITION_OFFSET; do
        TOPIC=$(echo $TOPIC_PARTITION_OFFSET | awk '{print $1}')
        PARTITION=$(echo $TOPIC_PARTITION_OFFSET | awk '{print $2}')
        OFFSET=$(echo $TOPIC_PARTITION_OFFSET | awk '{print $3}')

        # Skip the first line (header)
        if $FIRST_LINE; then
            FIRST_LINE=false
            continue
        fi

        # Check if the topic starts with LOWERED_NEW_SYSTEM_NAME followed by an underscore
        if [[ $TOPIC == ${LOWERED_NEW_SYSTEM_NAME}_* ]]; then
            if [[ $PARTITION =~ ^[0-9]+$ ]] && [[ $OFFSET =~ ^[0-9]+$ ]]; then
            # Print the topic, partition, and offset values
            echo "Processing topic: $TOPIC, partition: $PARTITION, offset: $OFFSET"

            # Execute the kafka-consumer-groups command
            kafka-consumer-groups.sh --bootstrap-server $TARGET_BOOTSTRAP_SERVERS --command-config /tmp/kcs.properties --group $NEW_CONSUMER_GROUP --topic $TOPIC:$PARTITION --reset-offsets --to-offset $OFFSET --execute      
            fi
        else
            echo "Skipping topic: $TOPIC (does not start with ${LOWERED_NEW_SYSTEM_NAME}_)"
        fi
    done <<< "$TOPIC_PARTITION_OFFSETS"

    # Delete the old consumer group
    kafka-consumer-groups.sh --bootstrap-server $TARGET_BOOTSTRAP_SERVERS --command-config /tmp/kcs.properties --delete --group $CONSUMER_GROUP

    echo "Consumer groups migrated."
done
